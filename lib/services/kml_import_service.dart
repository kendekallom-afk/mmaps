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

/// Membaca file KML/KMZ menjadi [ImportedMap].
///
/// Dirancang agar aman untuk HP RAM 2 GB. Semua batas di bawah adalah
/// TITIK AWAL yang konservatif. Ukur pemakaian memori di perangkat nyata
/// (Flutter DevTools, tab Memory) sebelum menaikkannya.
///
/// Alur pemrosesan (dua tahap, supaya puncak memori tidak menumpuk):
/// 1. Tahap vektor: decode teks, bangun DOM XML, ambil titik/garis/poligon
///    dan DAFTAR REFERENSI overlay. DOM dan teks dilepas setelah tahap ini.
/// 2. Tahap overlay: baru setelah DOM lepas, byte gambar dibaca dan
///    divalidasi (ukuran file dan dimensi piksel).
class KmlImportService {
  // ------------------------------------------
  // BATAS UKURAN FILE
  // ------------------------------------------

  /// Ukuran file mentah (KML/KMZ). Pakai konstanta ini juga di layar impor
  /// agar batasnya selalu sama.
  static const int maxInputBytes = 30 * 1024 * 1024;

  /// Ukuran dokumen KML (setelah KMZ diekstrak). DOM XML bisa memakan
  /// belasan kali lipat ukuran teksnya di memori.
  static const int maxDocumentBytes = 8 * 1024 * 1024;

  /// Batas jumlah entri dan total ukuran hasil ekstraksi arsip.
  /// Catatan: package archive mendekompresi arsip sebelum batas ini diperiksa,
  /// sehingga ini lapisan perlindungan tambahan, bukan pencegah lonjakan RAM.
  static const int maxArchiveEntries = 2000;
  static const int maxTotalExpandedBytes = 100 * 1024 * 1024;

  /// Ukuran file satu gambar overlay dan total semua gambar overlay.
  static const int maxOverlayBytes = 15 * 1024 * 1024;
  static const int maxTotalOverlayBytes = 40 * 1024 * 1024;

  // ------------------------------------------
  // BATAS KOMPLEKSITAS DATA
  // ------------------------------------------

  /// Jumlah fitur (titik + garis + poligon) dan total koordinat.
  static const int maxFeatures = 30000;
  static const int maxCoordinates = 300000;

  // ------------------------------------------
  // BATAS GAMBAR OVERLAY (berdasarkan piksel, bukan hanya byte file)
  // Gambar RGBA yang di-decode memakai kira-kira lebar x tinggi x 4 byte,
  // dan GPU punya batas ukuran tekstur (sering 4096 piksel per sisi).
  // ------------------------------------------

  static const int maxOverlayDimension = 4096;
  static const int maxTotalOverlayPixels = 12000000;
  static const int maxOverlayCount = 20;

  /// Set `false` jika `MapHomePage` belum merender `overlays` ke peta.
  /// Dengan begitu byte gambar tidak dibaca ke memori tanpa guna.
  static const bool loadOverlayImages = true;

  static final RegExp _spaceAroundComma = RegExp(r'\s,|,\s');
  static final RegExp _commaWithSpaces = RegExp(r'\s*,\s*');
  static final RegExp _imagePattern = RegExp(
    r'\.(png|jpe?g|webp)$',
    caseSensitive: false,
  );

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

    if (source.length > maxDocumentBytes) {
      throw FormatException(
        'Ukuran dokumen KML melebihi batas ${_mb(maxDocumentBytes)} MB.',
      );
    }

    // ---------- TAHAP 1: vektor (DOM hanya hidup di dalam fungsi ini) ----------
    final extraction = _extractVectors(source.takeBytes(), fileName);

    // ---------- TAHAP 2: overlay (DOM sudah lepas dari memori) ----------
    final overlays = loadOverlayImages
        ? _loadOverlays(extraction.overlayRefs, source)
        : const <MapRasterOverlay>[];

    if (extraction.points.isEmpty &&
        extraction.lines.isEmpty &&
        extraction.polygons.isEmpty &&
        overlays.isEmpty) {
      if (!loadOverlayImages && extraction.overlayRefs.isNotEmpty) {
        throw const FormatException(
          'File ini hanya berisi gambar overlay (GroundOverlay) yang belum didukung.',
        );
      }
      throw const FormatException(
        'Tidak ditemukan titik, garis, polygon, atau GroundOverlay KML yang didukung.',
      );
    }

    stopwatch.stop();

    if (kDebugMode) {
      debugPrint(
        '[KMZ PERF] $fileName | '
        'ukuran: ${(bytes.length / (1024 * 1024)).toStringAsFixed(2)} MB | '
        'parse: ${stopwatch.elapsedMilliseconds} ms | '
        'titik: ${extraction.points.length} | '
        'garis: ${extraction.lines.length} | '
        'poligon: ${extraction.polygons.length} | '
        'koordinat: ${extraction.coordinateCount} | '
        'overlay: ${overlays.length}',
      );
    }

    return ImportedMap(
      id: id,
      name: extraction.documentName,
      fileName: fileName,
      points: extraction.points,
      lines: extraction.lines,
      polygons: extraction.polygons,
      overlays: overlays,
    );
  }

  // ==========================================
  // TAHAP 1: EKSTRAKSI VEKTOR
  // ==========================================

  _Extraction _extractVectors(Uint8List kmlBytes, String fileName) {
    final xml = _parseXml(kmlBytes);

    // Satu kali penelusuran DOM untuk mengumpulkan elemen yang relevan.
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

    final points = <MapPointFeature>[];
    final lines = <MapLineFeature>[];
    final polygons = <MapPolygonFeature>[];

    var featureCount = 0;
    var coordinateCount = 0;

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
            final remainingCoordinates = maxCoordinates - coordinateCount;
            final coordinates = _coordinates(
              geometry,
              maxAllowedCoordinates: remainingCoordinates > 0 ? 1 : 0,
            );
            if (coordinates.isNotEmpty) {
              _checkFeatureCapacity(featureCount);
              points.add(
                MapPointFeature(
                  name: name,
                  point: coordinates.first,
                  color: style.iconColor ?? Colors.red,
                ),
              );
              featureCount++;
              coordinateCount++;
            }

          case 'LineString':
            final coordinates = _coordinates(
              geometry,
              maxAllowedCoordinates: maxCoordinates - coordinateCount,
            );
            if (coordinates.length >= 2) {
              _checkFeatureCapacity(featureCount);
              lines.add(
                MapLineFeature(
                  name: name,
                  points: coordinates,
                  color: style.lineColor ?? Colors.blue,
                  width: style.lineWidth,
                ),
              );
              featureCount++;
              coordinateCount += coordinates.length;
            }

          case 'Polygon':
            final outer = _firstDescendant(geometry, 'outerBoundaryIs');
            final outerPoints = outer == null
                ? <LatLng>[]
                : _coordinates(
                    outer,
                    maxAllowedCoordinates: maxCoordinates - coordinateCount,
                  );

            if (outerPoints.length >= 3) {
              _checkFeatureCapacity(featureCount);
              var polygonCoordinateCount = outerPoints.length;
              final holes = <List<LatLng>>[];
              for (final inner in geometry.descendantElements.where(
                (element) => element.localName == 'innerBoundaryIs',
              )) {
                final remaining = maxCoordinates -
                    coordinateCount - polygonCoordinateCount;
                final ring = _coordinates(
                  inner,
                  maxAllowedCoordinates: remaining,
                );
                polygonCoordinateCount += ring.length;
                if (ring.length >= 3) {
                  holes.add(ring);
                }
              }

              // `fill` bernilai 0 => tanpa isian.
              // Tanpa warna poligon => isian biru tipis.
              final Color fillColor;
              if (!style.fillEnabled) {
                fillColor = Colors.transparent;
              } else if (style.polyColor != null) {
                fillColor = style.polyColor!;
              } else {
                fillColor = Colors.blue.withValues(alpha: 0.18);
              }

              // `outline` bernilai 0 => tanpa garis tepi.
              final borderColor = style.outlineEnabled
                  ? (style.lineColor ?? Colors.blue)
                  : Colors.transparent;

              polygons.add(
                MapPolygonFeature(
                  name: name,
                  points: outerPoints,
                  holes: holes,
                  fillColor: fillColor,
                  borderColor: borderColor,
                ),
              );
              featureCount++;
              coordinateCount += polygonCoordinateCount;
            }
        }

        // Hentikan lebih awal jika data terlalu kompleks untuk perangkat.
        _checkComplexity(featureCount, coordinateCount);
      }
    }

    // Referensi overlay saja (nama, href, bounds). Byte gambar belum dibaca.
    final overlayRefs = <_OverlayRef>[];
    for (final groundOverlay in groundOverlays) {
      if (overlayRefs.length >= maxOverlayCount) {
        throw FormatException(
          'File memiliki terlalu banyak GroundOverlay (maksimum $maxOverlayCount).',
        );
      }
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

      overlayRefs.add(
        _OverlayRef(
          name: _nonEmpty(_childText(groundOverlay, 'name')) ?? href,
          href: href,
          bounds: bounds,
        ),
      );
    }

    final document = _firstDescendant(xml, 'Document');
    final documentName =
        _nonEmpty(document == null ? null : _childText(document, 'name')) ??
        _stripExtension(fileName);

    return _Extraction(
      documentName: documentName,
      points: points,
      lines: lines,
      polygons: polygons,
      overlayRefs: overlayRefs,
      coordinateCount: coordinateCount,
    );
  }

  void _checkFeatureCapacity(int currentFeatureCount) {
    if (currentFeatureCount >= maxFeatures) {
      throw FormatException(
        'File terlalu kompleks: maksimum ${maxFeatures ~/ 1000} ribu fitur. '
        'Sederhanakan atau pecah file ini.',
      );
    }
  }

  void _checkComplexity(int featureCount, int coordinateCount) {
    if (featureCount > maxFeatures) {
      throw FormatException(
        'File terlalu kompleks: lebih dari ${maxFeatures ~/ 1000} ribu fitur. '
        'Sederhanakan atau pecah file ini.',
      );
    }
    if (coordinateCount > maxCoordinates) {
      throw FormatException(
        'File terlalu kompleks: lebih dari ${maxCoordinates ~/ 1000} ribu '
        'koordinat. Sederhanakan atau pecah file ini.',
      );
    }
  }

  // ==========================================
  // TAHAP 2: OVERLAY GAMBAR
  // Catatan: atribut `rotation` pada LatLonBox dan `gx:LatLonQuad` belum
  // didukung, jadi overlay yang diputar akan salah posisi.
  // ==========================================

  List<MapRasterOverlay> _loadOverlays(
    List<_OverlayRef> refs,
    _KmlSource source,
  ) {
    final result = <MapRasterOverlay>[];
    var totalBytes = 0;
    var totalPixels = 0;

    for (final ref in refs) {
      final decodedHref = _safeDecode(ref.href);
      final asset =
          source.assets[_normalizeArchivePath(
            '${source.baseDirectory}$decodedHref',
          ).toLowerCase()] ??
          source.assets[_normalizeArchivePath(decodedHref).toLowerCase()];
      if (asset == null) continue;

      // Pemeriksaan awal memakai ukuran dari header ZIP (sebelum inflasi).
      if (asset.size > maxOverlayBytes ||
          totalBytes + asset.size > maxTotalOverlayBytes) {
        throw FormatException(
          'Gambar overlay "${ref.href}" terlalu besar. Batas: '
          '${_mb(maxOverlayBytes)} MB per gambar dan '
          '${_mb(maxTotalOverlayBytes)} MB total.',
        );
      }

      final imageBytes = asset.readBytes();
      if (imageBytes == null) continue;

      // Header ZIP bisa tidak jujur, jadi ukuran sebenarnya diperiksa lagi.
      // (Pemeriksaan ini terjadi SETELAH inflasi; ia mencegah pemrosesan
      // lanjutan, bukan lonjakan memori saat inflasi itu sendiri.)
      totalBytes += imageBytes.length;
      if (imageBytes.length > maxOverlayBytes ||
          totalBytes > maxTotalOverlayBytes) {
        throw FormatException(
          'Gambar overlay "${ref.href}" melebihi batas ukuran.',
        );
      }

      final size = _readImageSize(imageBytes);
      if (size == null || size.width <= 0 || size.height <= 0) {
        throw FormatException(
          'Ukuran gambar overlay "${ref.href}" tidak dapat dibaca. '
          'Gunakan PNG, JPEG, atau WebP yang valid.',
        );
      }

      if (size.width > maxOverlayDimension ||
          size.height > maxOverlayDimension) {
        throw FormatException(
          'Gambar overlay "${ref.href}" berukuran ${size.width}x${size.height} '
          'piksel. Maksimum $maxOverlayDimension piksel per sisi.',
        );
      }

      totalPixels += size.width * size.height;
      if (totalPixels > maxTotalOverlayPixels) {
        throw FormatException(
          'Total piksel gambar overlay melebihi '
          '${maxTotalOverlayPixels ~/ 1000000} megapiksel.',
        );
      }

      result.add(
        MapRasterOverlay(name: ref.name, bytes: imageBytes, bounds: ref.bounds),
      );
    }

    return result;
  }

  /// Membaca lebar dan tinggi gambar dari header, tanpa decode penuh.
  /// Mendukung PNG, JPEG, dan WebP. Mengembalikan null jika tidak dikenali.
  ({int width, int height})? _readImageSize(Uint8List b) {
    // PNG: lebar dan tinggi ada di chunk IHDR.
    if (b.length >= 24 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      return (width: w, height: h);
    }

    // JPEG: cari marker SOF.
    if (b.length > 4 && b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        if (marker == 0xFF) {
          i++;
          continue;
        }
        if (marker == 0xD8 ||
            marker == 0x01 ||
            (marker >= 0xD0 && marker <= 0xD7)) {
          i += 2;
          continue;
        }
        final length = (b[i + 2] << 8) | b[i + 3];
        if (marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          return (width: w, height: h);
        }
        i += 2 + length;
      }
      return null;
    }

    // WebP: RIFF....WEBP lalu chunk VP8X, VP8L, atau VP8.
    if (b.length > 30 && _matches(b, 0, 'RIFF') && _matches(b, 8, 'WEBP')) {
      if (_matches(b, 12, 'VP8X')) {
        final w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
        final h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
        return (width: w, height: h);
      }
      if (_matches(b, 12, 'VP8L') && b[20] == 0x2F) {
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return (width: (bits & 0x3FFF) + 1, height: ((bits >> 14) & 0x3FFF) + 1);
      }
      if (_matches(b, 12, 'VP8 ') &&
          b[23] == 0x9D &&
          b[24] == 0x01 &&
          b[25] == 0x2A) {
        final w = (b[26] | (b[27] << 8)) & 0x3FFF;
        final h = (b[28] | (b[29] << 8)) & 0x3FFF;
        return (width: w, height: h);
      }
    }

    return null;
  }

  bool _matches(Uint8List b, int offset, String text) {
    if (offset + text.length > b.length) return false;
    for (var i = 0; i < text.length; i++) {
      if (b[offset + i] != text.codeUnitAt(i)) return false;
    }
    return true;
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
      if (unit == 0xFEFF || _isSpaceUnit(unit)) {
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

  bool _isSpaceUnit(int unit) =>
      unit == 0x20 || unit == 0x09 || unit == 0x0A || unit == 0x0D;

  // ==========================================
  // PARSING STYLE KML
  // ==========================================

  /// Mendaftarkan `StyleMap`: memakai pasangan "normal" yang menunjuk
  /// ke `Style` (atau berisi `Style` inline).
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

    if (files.length > maxArchiveEntries) {
      throw FormatException(
        'KMZ memiliki terlalu banyak entri (${files.length}). '
        'Batas: $maxArchiveEntries entri.',
      );
    }

    var expandedBytes = 0;
    for (final file in files) {
      if (file.size < 0 || file.size > maxTotalExpandedBytes - expandedBytes) {
        throw FormatException(
          'Total isi KMZ setelah ekstraksi melebihi '
          '${_mb(maxTotalExpandedBytes)} MB.',
        );
      }
      expandedBytes += file.size;
    }

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

    // Pemeriksaan awal memakai ukuran dari header ZIP (sebelum inflasi).
    if (kmlFile.size > maxDocumentBytes) {
      throw FormatException(
        'Ukuran dokumen KML di dalam KMZ melebihi ${_mb(maxDocumentBytes)} MB.',
      );
    }

    final kmlBytes = kmlFile.readBytes() ?? Uint8List(0);

    // Header ZIP bisa tidak jujur, jadi ukuran sebenarnya diperiksa lagi.
    if (kmlBytes.length > maxDocumentBytes) {
      throw FormatException(
        'Ukuran dokumen KML di dalam KMZ melebihi ${_mb(maxDocumentBytes)} MB.',
      );
    }

    final baseDirectory = _parentDirectory(kmlFile.name);
    final assets = <String, ArchiveFile>{};

    for (final file in files) {
      final assetPath = _normalizeArchivePath(file.name).toLowerCase();
      if (!_imagePattern.hasMatch(assetPath)) continue;
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

  List<LatLng> _coordinates(
    XmlElement element, {
    int maxAllowedCoordinates = KmlImportService.maxCoordinates,
  }) {
    if (maxAllowedCoordinates < 0) {
      throw const FormatException('Batas koordinat terlampaui.');
    }
    final coordinateElement = _firstDescendant(element, 'coordinates');
    if (coordinateElement == null) return const [];

    var text = coordinateElement.innerText.trim();
    if (text.isEmpty) return const [];

    // Toleran terhadap format "lon, lat, alt" (ada spasi di sekitar koma).
    if (_spaceAroundComma.hasMatch(text)) {
      text = text.replaceAll(_commaWithSpaces, ',');
    }

    final result = <LatLng>[];
    final length = text.length;
    var i = 0;

    // Pemindai manual: tidak membuat daftar string raksasa dari split().
    while (i < length) {
      while (i < length && _isSpaceUnit(text.codeUnitAt(i))) {
        i++;
      }
      if (i >= length) break;

      final start = i;
      while (i < length && !_isSpaceUnit(text.codeUnitAt(i))) {
        i++;
      }

      final token = text.substring(start, i);
      final firstComma = token.indexOf(',');
      if (firstComma <= 0) continue;

      final secondComma = token.indexOf(',', firstComma + 1);
      final longitude = double.tryParse(token.substring(0, firstComma));
      final latitude = double.tryParse(
        token.substring(firstComma + 1, secondComma == -1 ? token.length : secondComma),
      );

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

      if (result.length >= maxAllowedCoordinates) {
        throw FormatException(
          'File terlalu kompleks: batas koordinat tersisa ($maxAllowedCoordinates) terlampaui. '
          'Sederhanakan atau pecah file ini.',
        );
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
// CLASS PENAMPUNG
// ==========================================

class _KmlStyle {
  Color? lineColor;
  Color? polyColor;
  Color? iconColor;

  double lineWidth = 3.0;
  bool fillEnabled = true;
  bool outlineEnabled = true;
}

/// Sumber dokumen. Byte KML diambil sekali lewat [takeBytes] lalu dilepas
/// dari objek ini, supaya tidak ikut tertahan selama tahap overlay.
class _KmlSource {
  Uint8List? _bytes;
  final Map<String, ArchiveFile> assets;
  final String baseDirectory;

  _KmlSource({
    required Uint8List bytes,
    required this.assets,
    required this.baseDirectory,
  }) : _bytes = bytes;

  int get length => _bytes?.length ?? 0;

  Uint8List takeBytes() {
    final bytes = _bytes ?? Uint8List(0);
    _bytes = null;
    return bytes;
  }
}

/// Referensi overlay hasil tahap 1 (byte gambar belum dibaca).
class _OverlayRef {
  final String name;
  final String href;
  final LatLngBounds bounds;

  const _OverlayRef({
    required this.name,
    required this.href,
    required this.bounds,
  });
}

/// Hasil tahap 1.
class _Extraction {
  final String documentName;
  final List<MapPointFeature> points;
  final List<MapLineFeature> lines;
  final List<MapPolygonFeature> polygons;
  final List<_OverlayRef> overlayRefs;
  final int coordinateCount;

  const _Extraction({
    required this.documentName,
    required this.points,
    required this.lines,
    required this.polygons,
    required this.overlayRefs,
    required this.coordinateCount,
  });
}