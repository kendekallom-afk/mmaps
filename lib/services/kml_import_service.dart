import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';

import '../models/imported_map.dart';

class KmlImportService {
  static const int maxDocumentBytes = 50 * 1024 * 1024;
  static const int maxOverlayBytes = 80 * 1024 * 1024;

  ImportedMap parse({
    required String id,
    required String fileName,
    required Uint8List bytes,
  }) {
    final extension = fileName.split('.').last.toLowerCase();
    if (extension != 'kml' && extension != 'kmz') {
      throw const FormatException('Pilih file dengan format .kml atau .kmz.');
    }
    if (bytes.length > 500 * 1024 * 1024) {
      throw const FormatException('Ukuran file melebihi batas 500 MB.');
    }

    final documentData = extension == 'kmz'
        ? _readKmz(bytes)
        : _KmlSource(bytes: bytes, assets: const {}, baseDirectory: '');
    if (documentData.bytes.length > maxDocumentBytes) {
      throw const FormatException('Ukuran dokumen KML melebihi batas 50 MB.');
    }

    final xml = XmlDocument.parse(utf8.decode(documentData.bytes));
    final pointFeatures = <MapPointFeature>[];
    final lineFeatures = <MapLineFeature>[];
    final polygonFeatures = <MapPolygonFeature>[];
    final rasterOverlays = <MapRasterOverlay>[];
    var totalOverlayBytes = 0;

    for (final placemark in xml.descendantElements.where(
      (element) => element.localName == 'Placemark',
    )) {
      final name = _childText(placemark, 'name') ?? 'Placemark';
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
                  color: Colors.red,
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
                  color: Colors.blue,
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
              polygonFeatures.add(
                MapPolygonFeature(
                  name: name,
                  points: outerPoints,
                  holes: holes,
                  fillColor: Colors.blue.withValues(alpha: 0.18),
                  borderColor: Colors.blue,
                ),
              );
            }
        }
      }
    }

    for (final groundOverlay in xml.descendantElements.where(
      (element) => element.localName == 'GroundOverlay',
    )) {
      final icon = _firstDescendant(groundOverlay, 'Icon');
      final href = icon == null ? null : _childText(icon, 'href');
      final box = _firstDescendant(groundOverlay, 'LatLonBox');
      if (href == null || box == null) continue;

      final bounds = _overlayBounds(box);
      if (bounds == null) continue;

      final assetPath = _normalizeArchivePath(
        '${documentData.baseDirectory}$href',
      );
      final assetFile = documentData.assets[assetPath.toLowerCase()];
      if (assetFile == null) continue;
      if (assetFile.size > maxOverlayBytes) {
        throw FormatException('Gambar overlay "$href" melebihi batas 80 MB.');
      }
      totalOverlayBytes += assetFile.size;
      if (totalOverlayBytes > 240 * 1024 * 1024) {
        throw const FormatException(
          'Total ukuran gambar overlay KMZ melebihi batas 240 MB.',
        );
      }
      final imageBytes = assetFile.readBytes();
      if (imageBytes == null) continue;

      rasterOverlays.add(
        MapRasterOverlay(
          name: _childText(groundOverlay, 'name') ?? href,
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

    final document = _firstDescendant(xml, 'Document');
    final documentName =
        (document == null ? null : _childText(document, 'name')) ?? fileName;

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

  _KmlSource _readKmz(Uint8List bytes) {
    final archive = ZipDecoder().decodeBytes(bytes);
    final files = archive.files.where((file) => file.isFile).toList();
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
      throw const FormatException(
        'Ukuran dokumen KML di dalam KMZ melebihi 50 MB.',
      );
    }

    final baseDirectory = _parentDirectory(kmlFile.name);
    final assets = <String, ArchiveFile>{};
    for (final file in files) {
      final path = _normalizeArchivePath(file.name).toLowerCase();
      if (!RegExp(
        r'\.(png|jpe?g|webp)$',
        caseSensitive: false,
      ).hasMatch(path)) {
        continue;
      }
      assets[path] = file;
    }

    return _KmlSource(
      bytes: kmlFile.readBytes() ?? Uint8List(0),
      assets: assets,
      baseDirectory: baseDirectory,
    );
  }

  List<LatLng> _coordinates(XmlElement element) {
    final coordinateElement = _firstDescendant(element, 'coordinates');
    if (coordinateElement == null) return const [];
    final result = <LatLng>[];
    for (final item in coordinateElement.innerText.trim().split(
      RegExp(r'\s+'),
    )) {
      final parts = item.split(',');
      if (parts.length < 2) continue;
      final longitude = double.tryParse(parts[0]);
      final latitude = double.tryParse(parts[1]);
      if (latitude == null ||
          longitude == null ||
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
    if (north < south ||
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

  String? _childText(XmlElement element, String name) {
    for (final child in element.childElements) {
      if (child.localName == name) return child.innerText.trim();
    }
    return null;
  }

  XmlElement? _firstDescendant(XmlNode element, String name) {
    for (final descendant in element.descendantElements) {
      if (descendant.localName == name) return descendant;
    }
    return null;
  }

  String _parentDirectory(String path) {
    final separator = path.lastIndexOf('/');
    return separator == -1 ? '' : path.substring(0, separator + 1);
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
