import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';

import '../models/imported_map.dart';

/// Fungsi top-level agar bisa dipakai dengan `compute(...)` (isolate).
ImportedMap parseKmlInBackground(
  ({String id, String fileName, Uint8List bytes}) input,
) {
  return KmlImportService().parse(
    id: input.id,
    fileName: input.fileName,
    bytes: input.bytes,
  );
}

class KmlImportService {
  /// Batas ukuran file mentah (KML/KMZ). Samakan dengan batas di layar impor.
  static const int maxInputBytes = 100 * 1024 * 1024;

  /// Batas ukuran dokumen KML (setelah KMZ diekstrak).
  /// Parser XML membangun DOM penuh di memori yang bisa belasan kali lipat
  /// dari ukuran teksnya, jadi angka ini sengaja dibuat konservatif.
  /// Naikkan hanya setelah diuji di perangkat Android kelas menengah.
  static const int maxDocumentBytes = 20 * 1024 * 1024;

  /// Batas satu gambar overlay dan total semua gambar overlay.
  static const int maxOverlayBytes = 80 * 1024 * 1024;
  static const int maxTotalOverlayBytes = 240 * 1024 * 1024;

  ImportedMap parse({
    required String id,
    required String fileName,
    required Uint8List bytes,
  }) {
    final stopwatch = Stopwatch()..start();

    final extension = fileName.contains('.')
        ? fileName.split('.').last.toLowerCase()
        : '';

    if (extension != 'kml' && extension != 'kmz') {
      throw const FormatException('Pilih file dengan format .kml atau .kmz.');
    }

    if (bytes.length > maxInputBytes) {
      throw FormatException(
        'Ukuran file melebihi batas ${_mb(maxInputBytes)} MB.',
      );
    }

    final source = extension == 'kmz'
        ? _readKmz(bytes)
        : _KmlSource(bytes: bytes, assets: const {}, baseDirectory: '');

    if (source.bytes.length > maxDocumentBytes) {
      throw FormatException(
        'Ukuran dokumen KML melebihi batas ${_mb(maxDocumentBytes)} MB.',
      );
    }

    final xml = _parseXml(source.bytes);

    // Satu kali penelusuran DOM untuk mengumpulkan semua elemen yang relevan.
    final styleElements = <XmlElement>[];
    final styleMapElements = <XmlElement>[];
    final placemarks = <XmlElement>[];
    final groundOverlays = <XmlElement>[];

    for (final element in xml.descendantElements) {
      switch (element.localName) {
        case 'Style':
          if (element.getAttribute('id') != null) styleElements.add(element);
        case 'StyleMap':
          if (element.getAttribute('id') != null) styleMapElements.add(element);
        case 'Placemark':
          placemarks.add(element);
        case 'GroundOverlay':
          groundOverlays.add(element);
      }
    }

    // Style global, lalu StyleMap (yang merujuk ke Style).
    final styles = <String, _KmlStyle>{};
    for (final style in styleElements) {
      styles[style.getAttribute('id')!] = _parseStyleElement(style);
    }
    _registerStyleMaps(styleMapElements, styles);

    final pointFeatures = <MapPointFeature>[];
    final lineFeatures = <MapLineFeature>[];
    final polygonFeatures = <MapPolygonFeature>[];
    final rasterOverlays = <MapRasterOverlay>[];

    // ==========================================
    // PLACEMARK & GEOMETRI
    // ==========================================
    for (final placemark in placemarks) {
      final name = _nonEmpty(_childText(placemark, 'name')) ?? 'Placemark';
      final style = _resolveStyle(placemark, styles);

      for (final geometry in placemark.descendantElements.where(
        (element) => const {
          'Point',
          'LineString',
          'Polygon',
        }.contains(element.localName),
      )) {
        switch (geometry.localName) {
          case 'Point':
            final coordinates = _coordinates(geometry);
            if (coordinates.isNotEmpty) {
              pointFeatures.add(
                MapPointFeature(
                  name: name,
                  point: coordinates.first,
                  color: style.iconColor ?? Colors.red,
                ),
              );
            }

          case 'LineString':
            final coordinates = _coordinates(geometry);
            if (coordinates.length >= 2) {
              lineFeatures.add(
                MapLineFeature(
                  name: name,
                  points: coordinates,
                  color: style.lineColor ?? Colors.blue,
                  width: style.lineWidth,
                ),
              );
            }

          case 'Polygon':
            final outer = _firstDescendant(geometry, 'outerBoundaryIs');
            final outerPoints = outer == null
                ? <LatLng>[]
                : _coordinates(outer);

            if (outerPoints.length >= 3) {
              final holes = geometry.descendantElements
                  .where((element) => element.localName == 'innerBoundaryIs')
                  .map(_coordinates)
                  .where((ring) => ring.length >= 3)
                  .toList();

              // <fill>0</fill> => tanpa isian. Tanpa <color> => isian biru tipis.
              final Color fillColor;
              if (!style.fillEnabled) {
                fillColor = Colors.transparent;
              } else if (style.polyColor != null) {
                fillColor = style.polyColor!;
              } else {
                fillColor = Colors.blue.withValues(alpha: 0.18);
              }

              // <outline>0</outline> => tanpa garis tepi.
              final borderColor = style.outlineEnabled
                  ? (style.lineColor ?? Colors.blue)
                  : Colors.transparent;

              polygonFeatures.add(
                MapPolygonFeature(
                  name: name,
                  points: outerPoints,
                  holes: holes,
                  fillColor: fillColor,
                  borderColor: borderColor,
                ),
              );
            }
        }
      }
    }

    // ==========================================
    // GROUND OVERLAY (gambar bergeoreferensi)
    // Catatan: atribut <rotation> pada LatLonBox dan gx:LatLonQuad
    // belum didukung, jadi overlay yang diputar akan salah posisi.
    // ==========================================
    var totalOverlayBytes = 0;

    for (final groundOverlay in groundOverlays) {
      final icon = _firstDescendant(groundOverlay, 'Icon');
      final href = _nonEmpty(icon == null ? null : _childText(icon, 'href'));
      final box = _firstDescendant(groundOverlay, 'LatLonBox');

      if (href == null || box == null) continue;

      // Gambar dari internet tidak diambil (harus ada di dalam KMZ).
      final lowerHref = href.toLowerCase();
      if (lowerHref.startsWith('http://') || lowerHref.startsWith('https://')) {
        continue;
      }

      final bounds = _overlayBounds(box);
      if (bounds == null) continue;

      final decodedHref = _safeDecode(href);
      final assetFile =
          source.assets[_normalizeArchivePath(
            '${source.baseDirectory}$decodedHref',
          ).toLowerCase()] ??
          source.assets[_normalizeArchivePath(decodedHref).toLowerCase()];
      if (assetFile == null) continue;

      if (assetFile.size > maxOverlayBytes) {
        throw FormatException(
          'Gambar overlay "$href" melebihi batas ${_mb(maxOverlayBytes)} MB.',
        );
      }

      final imageBytes = assetFile.readBytes();
      if (imageBytes == null) continue;

      // Periksa ukuran sebenarnya setelah dekompresi (header ZIP bisa tidak jujur).
      if (imageBytes.length > maxOverlayBytes) {
        throw FormatException(
          'Gambar overlay "$href" melebihi batas ${_mb(maxOverlayBytes)} MB.',
        );
      }

      totalOverlayBytes += imageBytes.length;
      if (totalOverlayBytes > maxTotalOverlayBytes) {
        throw FormatException(
          'Total ukuran gambar overlay KMZ melebihi batas '
          '${_mb(maxTotalOverlayBytes)} MB.',
        );
      }

      rasterOverlays.add(
        MapRasterOverlay(
          name: _nonEmpty(_childText(groundOverlay, 'name')) ?? href,
          bytes: imageBytes,
          bounds: bounds,
        ),
      );
    }

    if (pointFeatures.isEmpty &&
        lineFeatures.isEmpty &&
        polygonFeatures.isEmpty &&
        rasterOverlays.isEmpty) {
      throw const FormatException(
        'Tidak ditemukan titik, garis, polygon, atau GroundOverlay KML yang didukung.',
      );
    }

    stopwatch.stop();

    if (kDebugMode) {
      final lineCoordinateCount = lineFeatures.fold<int>(
        0,
        (total, feature) => total + feature.points.length,
      );
      final polygonCoordinateCount = polygonFeatures.fold<int>(
        0,
        (total, feature) =>
            total +
            feature.points.length +
            feature.holes.fold<int>(0, (sum, ring) => sum + ring.length),
      );
      debugPrint(
        '[KMZ PERF] $fileName | '
        'ukuran: ${(bytes.length / (1024 * 1024)).toStringAsFixed(2)} MB | '
        'parse: ${stopwatch.elapsedMilliseconds} ms | '
        'titik: ${pointFeatures.length} | '
        'garis: ${lineFeatures.length} | '
        'poligon: ${polygonFeatures.length} | '
        'koordinat: ${pointFeatures.length + lineCoordinateCount + polygonCoordinateCount} | '
        'overlay: ${rasterOverlays.length}',
      );
    }

    final document = _firstDescendant(xml, 'Document');
    final documentName =
        _nonEmpty(document == null ? null : _childText(document, 'name')) ??
        _stripExtension(fileName);

    return ImportedMap(
      id: id,
      name: documentName,
      fileName: fileName,
      points: pointFeatures,
      lines: lineFeatures,
      polygons: polygonFeatures,
      overlays: rasterOverlays,
    );
  }

  // ==========================================
  // XML
  // ==========================================

  XmlDocument _parseXml(Uint8List data) {
    var text = utf8.decode(data, allowMalformed: true);

    // Buang BOM dan spasi/baris kosong sebelum deklarasi XML.
    var start = 0;
    while (start < text.length) {
      final unit = text.codeUnitAt(start);
      if (unit == 0xFEFF ||
          unit == 0x20 ||
          unit == 0x09 ||
          unit == 0x0A ||
          unit == 0x0D) {
        start++;
      } else {
        break;
      }
    }
    if (start > 0) text = text.substring(start);

    try {
      return XmlDocument.parse(text);
    } on XmlException catch (error) {
      throw FormatException('File KML tidak valid: ${error.message}');
    }
  }

  // ==========================================
  // PARSING STYLE KML
  // ==========================================

  /// Mendaftarkan `<StyleMap>`: memakai pasangan "normal" yang menunjuk
  /// ke `<Style>` (atau berisi `<Style>` inline).
  void _registerStyleMaps(
    List<XmlElement> styleMapElements,
    Map<String, _KmlStyle> styles,
  ) {
    for (final styleMap in styleMapElements) {
      final id = styleMap.getAttribute('id');
      if (id == null) continue;

      for (final pair in styleMap.childElements) {
        if (pair.localName != 'Pair') continue;
        if (_childText(pair, 'key') != 'normal') continue;

        final target = _styleFromUrl(_childText(pair, 'styleUrl'), styles);
        if (target != null) {
          styles[id] = target;
        } else {
          final inline = _firstChild(pair, 'Style');
          if (inline != null) styles[id] = _parseStyleElement(inline);
        }
        break;
      }
    }
  }

  _KmlStyle? _styleFromUrl(String? url, Map<String, _KmlStyle> styles) {
    if (url == null || url.isEmpty) return null;
    final hashIndex = url.lastIndexOf('#');
    if (hashIndex == -1) return null;
    return styles[url.substring(hashIndex + 1)];
  }

  _KmlStyle _resolveStyle(XmlElement placemark, Map<String, _KmlStyle> styles) {
    final inlineStyle = _firstChild(placemark, 'Style');
    if (inlineStyle != null) return _parseStyleElement(inlineStyle);

    return _styleFromUrl(_childText(placemark, 'styleUrl'), styles) ??
        _KmlStyle();
  }

  _KmlStyle _parseStyleElement(XmlElement styleElement) {
    final result = _KmlStyle();

    final lineStyle = _firstChild(styleElement, 'LineStyle');
    if (lineStyle != null) {
      final colorStr = _childText(lineStyle, 'color');
      if (colorStr != null) result.lineColor = _parseKmlColor(colorStr);

      final widthStr = _childText(lineStyle, 'width');
      if (widthStr != null) {
        result.lineWidth = double.tryParse(widthStr) ?? 3.0;
      }
    }

    final polyStyle = _firstChild(styleElement, 'PolyStyle');
    if (polyStyle != null) {
      final colorStr = _childText(polyStyle, 'color');
      if (colorStr != null) result.polyColor = _parseKmlColor(colorStr);

      final fillStr = _childText(polyStyle, 'fill');
      if (fillStr != null && _isFalse(fillStr)) result.fillEnabled = false;

      final outlineStr = _childText(polyStyle, 'outline');
      if (outlineStr != null && _isFalse(outlineStr)) {
        result.outlineEnabled = false;
      }
    }

    final iconStyle = _firstChild(styleElement, 'IconStyle');
    if (iconStyle != null) {
      final colorStr = _childText(iconStyle, 'color');
      if (colorStr != null) result.iconColor = _parseKmlColor(colorStr);
    }

    return result;
  }

  bool _isFalse(String value) {
    final v = value.trim().toLowerCase();
    return v == '0' || v == 'false';
  }

  /// Mengubah warna KML (AABBGGRR, atau BBGGRR) menjadi warna Flutter.
  Color? _parseKmlColor(String kmlHex) {
    var hex = kmlHex.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length == 6) hex = 'ff$hex';
    if (hex.length != 8) return null;

    final a = int.tryParse(hex.substring(0, 2), radix: 16);
    final b = int.tryParse(hex.substring(2, 4), radix: 16);
    final g = int.tryParse(hex.substring(4, 6), radix: 16);
    final r = int.tryParse(hex.substring(6, 8), radix: 16);
    if (a == null || b == null || g == null || r == null) return null;

    return Color.fromARGB(a, r, g, b);
  }

  // ==========================================
  // PARSING FILE & GEOMETRI
  // ==========================================

  _KmlSource _readKmz(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      throw const FormatException(
        'File KMZ rusak atau bukan arsip ZIP yang valid.',
      );
    }

    final files = archive.files
        .where((file) => file.isFile && !_isJunkEntry(file.name))
        .toList();

    final kmlFiles = files
        .where((file) => file.name.toLowerCase().endsWith('.kml'))
        .toList();

    if (kmlFiles.isEmpty) {
      throw const FormatException('KMZ ini tidak berisi file KML.');
    }

    final kmlFile = kmlFiles.firstWhere(
      (file) => file.name.toLowerCase().split('/').last == 'doc.kml',
      orElse: () => kmlFiles.first,
    );

    if (kmlFile.size > maxDocumentBytes) {
      throw FormatException(
        'Ukuran dokumen KML di dalam KMZ melebihi ${_mb(maxDocumentBytes)} MB.',
      );
    }

    final kmlBytes = kmlFile.readBytes() ?? Uint8List(0);

    // Periksa ukuran sebenarnya setelah dekompresi.
    if (kmlBytes.length > maxDocumentBytes) {
      throw FormatException(
        'Ukuran dokumen KML di dalam KMZ melebihi ${_mb(maxDocumentBytes)} MB.',
      );
    }

    final baseDirectory = _parentDirectory(kmlFile.name);
    final assets = <String, ArchiveFile>{};
    final imagePattern = RegExp(r'\.(png|jpe?g|webp)$', caseSensitive: false);

    for (final file in files) {
      final assetPath = _normalizeArchivePath(file.name).toLowerCase();
      if (!imagePattern.hasMatch(assetPath)) continue;
      assets[assetPath] = file;
    }

    return _KmlSource(
      bytes: kmlBytes,
      assets: assets,
      baseDirectory: baseDirectory,
    );
  }

  /// Entri sampah buatan macOS ("__MACOSX/", "._nama").
  bool _isJunkEntry(String path) {
    final normalized = path.replaceAll('\\', '/').toLowerCase();
    if (normalized.startsWith('__macosx/')) return true;
    return normalized.split('/').last.startsWith('._');
  }

  List<LatLng> _coordinates(XmlElement element) {
    final coordinateElement = _firstDescendant(element, 'coordinates');
    if (coordinateElement == null) return const [];

    final text = coordinateElement.innerText.trim();
    if (text.isEmpty) return const [];

    // Toleran terhadap format "lon, lat, alt" (ada spasi di sekitar koma).
    final normalized = text.replaceAll(RegExp(r'\s*,\s*'), ',');

    final result = <LatLng>[];

    for (final item in normalized.split(RegExp(r'\s+'))) {
      final parts = item.split(',');
      if (parts.length < 2) continue;

      final longitude = double.tryParse(parts[0]);
      final latitude = double.tryParse(parts[1]);

      if (latitude == null ||
          longitude == null ||
          !latitude.isFinite ||
          !longitude.isFinite ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180) {
        continue;
      }

      result.add(LatLng(latitude, longitude));
    }

    return result;
  }

  LatLngBounds? _overlayBounds(XmlElement box) {
    final north = double.tryParse(_childText(box, 'north') ?? '');
    final south = double.tryParse(_childText(box, 'south') ?? '');
    final east = double.tryParse(_childText(box, 'east') ?? '');
    final west = double.tryParse(_childText(box, 'west') ?? '');

    if (north == null || south == null || east == null || west == null) {
      return null;
    }

    if (!north.isFinite ||
        !south.isFinite ||
        !east.isFinite ||
        !west.isFinite ||
        north < south ||
        north > 90 ||
        south < -90 ||
        east < -180 ||
        east > 180 ||
        west < -180 ||
        west > 180) {
      return null;
    }

    return LatLngBounds.fromPoints([LatLng(north, west), LatLng(south, east)]);
  }

  // ==========================================
  // UTILITAS
  // ==========================================

  String? _childText(XmlElement element, String name) {
    for (final child in element.childElements) {
      if (child.localName == name) return child.innerText.trim();
    }
    return null;
  }

  XmlElement? _firstChild(XmlElement element, String name) {
    for (final child in element.childElements) {
      if (child.localName == name) return child;
    }
    return null;
  }

  XmlElement? _firstDescendant(XmlNode element, String name) {
    for (final descendant in element.descendantElements) {
      if (descendant.localName == name) return descendant;
    }
    return null;
  }

  /// Mengubah string kosong/spasi menjadi null.
  String? _nonEmpty(String? value) {
    if (value == null) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _stripExtension(String fileName) {
    return fileName.replaceAll(
      RegExp(r'\.(kml|kmz)$', caseSensitive: false),
      '',
    );
  }

  String _safeDecode(String value) {
    try {
      return Uri.decodeFull(value);
    } catch (_) {
      return value;
    }
  }

  String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(0);

  String _parentDirectory(String path) {
    final normalized = path.replaceAll('\\', '/');
    final separator = normalized.lastIndexOf('/');
    return separator == -1 ? '' : normalized.substring(0, separator + 1);
  }

  String _normalizeArchivePath(String path) {
    final parts = <String>[];

    for (final part in path.replaceAll('\\', '/').split('/')) {
      if (part.isEmpty || part == '.') continue;

      if (part == '..') {
        if (parts.isNotEmpty) parts.removeLast();
      } else {
        parts.add(part);
      }
    }

    return parts.join('/');
  }
}

// ==========================================
// CLASS PENAMPUNG STYLE KML
// ==========================================

class _KmlStyle {
  Color? lineColor;
  Color? polyColor;
  Color? iconColor;

  double lineWidth = 3.0;
  bool fillEnabled = true;
  bool outlineEnabled = true;
}

class _KmlSource {
  final Uint8List bytes;
  final Map<String, ArchiveFile> assets;
  final String baseDirectory;

  const _KmlSource({
    required this.bytes,
    required this.assets,
    required this.baseDirectory,
  });
}