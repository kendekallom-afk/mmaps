import 'dart:convert';
import 'dart:typed_data';
import 'dart:async';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart';
import 'package:xml/xml_events.dart';

import '../models/imported_map.dart';
import '../models/import_package.dart';
import '../models/map_overlay_manifest.dart';

export '../models/import_package.dart'
    show ImportIssue, ImportIssueCode, ImportIssueSeverity, ImportParseResult;

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

  static const int maxInputBytes = 75 * 1024 * 1024;
  static const int maxDocumentBytes = 75 * 1024 * 1024;
  static const int maxArchiveEntries = 2000;
  static const int maxTotalExpandedBytes = 100 * 1024 * 1024;

  static const int maxOverlayBytes = 15 * 1024 * 1024;
  static const int maxTotalOverlayBytes = 40 * 1024 * 1024;

  // ------------------------------------------
  // BATAS KOMPLEKSITAS DATA
  // ------------------------------------------

  static const int maxFeatures = 30000;
  static const int maxCoordinates = 300000;

  // ------------------------------------------
  // BATAS GAMBAR OVERLAY
  // ------------------------------------------

  static const int maxOverlayDimension = 4096;
  static const int maxTotalOverlayPixels = 12000000;
  static const int maxOverlayCount = 20;

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
    final result = parseWithIssues(id: id, fileName: fileName, bytes: bytes);
    final errors = result.issues
        .where((issue) => issue.severity == ImportIssueSeverity.error)
        .toList();
    if (errors.isNotEmpty) {
      throw FormatException(errors.map((issue) => issue.message).join('\n'));
    }
    return result.map;
  }

  ImportParseResult parseWithIssues({
    required String id,
    required String fileName,
    required Uint8List bytes,
  }) {
    final stopwatch = Stopwatch()..start();
    final issues = <ImportIssue>[];

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

    // ---------- TAHAP 1: vektor ----------
    final extraction = _extractVectors(source.takeBytes(), fileName, issues);

    // ---------- TAHAP 2: overlay ----------
    final overlays = loadOverlayImages
        ? _loadOverlays(extraction.overlayRefs, source, issues)
        : const <MapRasterOverlay>[];

    if (!loadOverlayImages && extraction.overlayRefs.isNotEmpty) {
      for (var i = 0; i < extraction.overlayRefs.length; i++) {
        issues.add(
          ImportIssue(
            code: ImportIssueCode.unsupportedContent,
            severity: ImportIssueSeverity.error,
            message: 'GroundOverlay image loading is disabled.',
            sourceReference: extraction.overlayRefs[i].href,
            sourceOrder: i,
          ),
        );
      }
    }

    if (extraction.points.isEmpty &&
        extraction.lines.isEmpty &&
        extraction.polygons.isEmpty &&
        overlays.isEmpty) {
      if (issues.isEmpty) {
        issues.add(
          const ImportIssue(
            code: ImportIssueCode.noRenderableContent,
            severity: ImportIssueSeverity.error,
            message: 'No supported point, line, polygon, or GroundOverlay was found.',
          ),
        );
      }
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

    return ImportParseResult(
      map: ImportedMap(
        id: id,
        name: extraction.documentName,
        fileName: fileName,
        points: extraction.points,
        lines: extraction.lines,
        polygons: extraction.polygons,
        overlays: overlays,
      ),
      issues: issues,
    );
  }

  // ==========================================
  // TAHAP 1: EKSTRAKSI VEKTOR
  // ==========================================

  _Extraction _extractVectors(
    Uint8List kmlBytes,
    String fileName,
    List<ImportIssue> issues,
  ) {
    final xml = _parseXml(kmlBytes);

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

    final styles = <String, _KmlStyle>{};
    for (final style in styleElements) {
      styles[style.getAttribute('id')!] = _parseStyleElement(style);
    }
    _registerStyleMaps(styleMapElements, styles);
    _reportUnpreservedDocumentContent(xml, issues);
    _reportUnsupportedStyleContent(xml, issues);
    _reportUnpreservedNonStyleAttributes(xml, issues);

    final points = <MapPointFeature>[];
    final lines = <MapLineFeature>[];
    final polygons = <MapPolygonFeature>[];

    var featureCount = 0;
    var coordinateCount = 0;

    var geometryOrder = 0;
    for (final placemark in placemarks) {
      final name = _nonEmpty(_childText(placemark, 'name')) ?? 'Placemark';
      _reportUnpreservedPlacemarkContent(
        placemark,
        name,
        styles,
        geometryOrder,
        issues,
      );
      _reportUnpreservedPlacemarkGeometryContent(
        placemark,
        name,
        geometryOrder,
        issues,
      );
      final style = _resolveStyle(placemark, styles);

      for (final geometry in placemark.descendantElements.where(
        (element) => const {
          'Point',
          'LineString',
          'Polygon',
        }.contains(element.localName),
      )) {
        final currentGeometryOrder = geometryOrder++;
        final sourceReference = _elementSourceReference(geometry);
        if (geometry.localName == 'Polygon' && style.lineWidthExplicit) {
          issues.add(
            ImportIssue(
              code: ImportIssueCode.unsupportedContent,
              severity: ImportIssueSeverity.warning,
              message:
                  '$sourceReference uses a line width that the polygon model cannot preserve.',
              sourceReference: sourceReference,
              sourceOrder: currentGeometryOrder,
            ),
          );
        }
        switch (geometry.localName) {
          case 'Point':
            final remainingCoordinates = maxCoordinates - coordinateCount;
            final coordinates = _coordinates(
              geometry,
              maxAllowedCoordinates: remainingCoordinates > 0 ? 1 : 0,
              issues: issues,
              sourceReference: sourceReference,
              sourceOrder: currentGeometryOrder,
            );
            if (coordinates.points.isNotEmpty) {
              _checkFeatureCapacity(featureCount);
              points.add(
                MapPointFeature(
                  name: name,
                  point: coordinates.points.first,
                  altitude: coordinates.altitudes.first,
                  color: style.iconColor ?? Colors.red,
                ),
              );
              featureCount++;
              coordinateCount++;
            } else {
              issues.add(
                ImportIssue(
                  code: ImportIssueCode.invalidGeometry,
                  severity: ImportIssueSeverity.error,
                  message: '$sourceReference has no valid coordinate.',
                  sourceReference: sourceReference,
                  sourceOrder: currentGeometryOrder,
                ),
              );
            }

          case 'LineString':
            final coordinates = _coordinates(
              geometry,
              maxAllowedCoordinates: maxCoordinates - coordinateCount,
              issues: issues,
              sourceReference: sourceReference,
              sourceOrder: currentGeometryOrder,
            );
            if (coordinates.points.length >= 2) {
              _checkFeatureCapacity(featureCount);
              lines.add(
                MapLineFeature(
                  name: name,
                  points: coordinates.points,
                  altitudes: coordinates.altitudes,
                  color: style.lineColor ?? Colors.blue,
                  width: style.lineWidth,
                ),
              );
              featureCount++;
              coordinateCount += coordinates.points.length;
            } else {
              issues.add(
                ImportIssue(
                  code: ImportIssueCode.invalidGeometry,
                  severity: ImportIssueSeverity.error,
                  message: '$sourceReference has fewer than two coordinates.',
                  sourceReference: sourceReference,
                  sourceOrder: currentGeometryOrder,
                ),
              );
            }

          case 'Polygon':
            final outer = _firstDescendant(geometry, 'outerBoundaryIs');
            final outerCoordinates = outer == null
                ? const _ParsedCoordinates.empty()
                : _coordinates(
                    outer,
                    maxAllowedCoordinates: maxCoordinates - coordinateCount,
                    issues: issues,
                    sourceReference: '$sourceReference exterior ring',
                    sourceOrder: currentGeometryOrder,
                  );
            final outerPoints = outerCoordinates.points;

            if (outerPoints.length >= 3) {
              _checkFeatureCapacity(featureCount);
              var polygonCoordinateCount = outerPoints.length;
              final holes = <List<LatLng>>[];
              final holeAltitudes = <List<double?>>[];
              for (final inner in geometry.descendantElements.where(
                (element) => element.localName == 'innerBoundaryIs',
              )) {
                final remaining =
                    maxCoordinates - coordinateCount - polygonCoordinateCount;
                final ring = _coordinates(
                  inner,
                  maxAllowedCoordinates: remaining,
                  issues: issues,
                  sourceReference: '$sourceReference interior ring',
                  sourceOrder: currentGeometryOrder,
                );
                polygonCoordinateCount += ring.points.length;
                if (ring.points.length >= 3) {
                  holes.add(ring.points);
                  holeAltitudes.add(ring.altitudes);
                } else {
                  issues.add(
                    ImportIssue(
                      code: ImportIssueCode.invalidGeometry,
                      severity: ImportIssueSeverity.error,
                      message:
                          '$sourceReference contains an invalid interior ring.',
                      sourceReference: sourceReference,
                      sourceOrder: currentGeometryOrder,
                    ),
                  );
                }
              }

              final Color fillColor;
              if (!style.fillEnabled) {
                fillColor = Colors.transparent;
              } else if (style.polyColor != null) {
                fillColor = style.polyColor!;
              } else {
                fillColor = Colors.blue.withValues(alpha: 0.18);
              }

              final borderColor = style.outlineEnabled
                  ? (style.lineColor ?? Colors.blue)
                  : Colors.transparent;

              polygons.add(
                MapPolygonFeature(
                  name: name,
                  points: outerPoints,
                  altitudes: outerCoordinates.altitudes,
                  holes: holes,
                  holeAltitudes: holeAltitudes,
                  fillColor: fillColor,
                  borderColor: borderColor,
                ),
              );
              featureCount++;
              coordinateCount += polygonCoordinateCount;
            } else {
              issues.add(
                ImportIssue(
                  code: ImportIssueCode.invalidGeometry,
                  severity: ImportIssueSeverity.error,
                  message:
                      '$sourceReference has no valid exterior ring with at least three coordinates.',
                  sourceReference: sourceReference,
                  sourceOrder: currentGeometryOrder,
                ),
              );
            }
        }

        _checkComplexity(featureCount, coordinateCount);
      }
    }

    final overlayRefs = <_OverlayRef>[];
    for (
      var overlayOrder = 0;
      overlayOrder < groundOverlays.length;
      overlayOrder++
    ) {
      final groundOverlay = groundOverlays[overlayOrder];
      if (overlayRefs.length >= maxOverlayCount) {
        throw FormatException(
          'File memiliki terlalu banyak GroundOverlay (maksimum $maxOverlayCount).',
        );
      }
      final icon = _firstDescendant(groundOverlay, 'Icon');
      final href = _nonEmpty(icon == null ? null : _childText(icon, 'href'));
      final overlayName =
          _nonEmpty(_childText(groundOverlay, 'name')) ??
          'GroundOverlay ${overlayOrder + 1}';
      final box = _firstDescendant(groundOverlay, 'LatLonBox');

      void addOverlayIssue(ImportIssueCode code, String message) {
        issues.add(
          ImportIssue(
            code: code,
            severity: ImportIssueSeverity.error,
            message: message,
            sourceReference:
                '${_elementSourceReference(groundOverlay)}'
                '${href == null ? '' : ' href="$href"'}',
            sourceOrder: overlayOrder,
          ),
        );
      }

      if (_firstDescendant(groundOverlay, 'LatLonQuad') != null) {
        addOverlayIssue(
          ImportIssueCode.unsupportedOverlayBehavior,
          '$overlayName uses LatLonQuad, which is not supported.',
        );
      }

      for (final unsupportedElement in const [
        'altitude',
        'altitudeMode',
        'drawOrder',
        'color',
        'visibility',
      ]) {
        if (_firstDescendant(groundOverlay, unsupportedElement) != null) {
          addOverlayIssue(
            ImportIssueCode.unsupportedOverlayBehavior,
            '$overlayName uses unsupported $unsupportedElement behavior.',
          );
        }
      }

      if (box != null) {
        final rotationText = _childText(box, 'rotation');
        if (rotationText != null) {
          final rotation = double.tryParse(rotationText);
          if (rotation == null || !rotation.isFinite || rotation != 0) {
            addOverlayIssue(
              ImportIssueCode.unsupportedOverlayBehavior,
              '$overlayName has a rotation that cannot be preserved.',
            );
          }
        }
      }

      if (icon != null) {
        for (final unsupportedElement in const [
          'refreshMode',
          'refreshInterval',
          'viewRefreshMode',
          'viewRefreshTime',
          'viewBoundScale',
          'viewFormat',
          'httpQuery',
        ]) {
          if (_firstDescendant(icon, unsupportedElement) != null) {
            addOverlayIssue(
              ImportIssueCode.unsupportedOverlayBehavior,
              '$overlayName uses unsupported Icon $unsupportedElement behavior.',
            );
          }
        }
      }

      if (href == null) {
        addOverlayIssue(
          ImportIssueCode.missingOverlayReference,
          '$overlayName has no image href.',
        );
        continue;
      }

      if (_isRemoteReference(href)) {
        addOverlayIssue(
          ImportIssueCode.remoteOverlayReference,
          '$overlayName refers to a remote image, which is not fetched.',
        );
        continue;
      }

      if (box == null) {
        addOverlayIssue(
          ImportIssueCode.missingOverlayBounds,
          '$overlayName has no supported LatLonBox bounds.',
        );
        continue;
      }

      final bounds = _overlayBounds(box);
      if (bounds == null) {
        addOverlayIssue(
          ImportIssueCode.invalidOverlayBounds,
          '$overlayName has invalid geographic bounds.',
        );
        continue;
      }

      overlayRefs.add(
        _OverlayRef(
          name: overlayName,
          href: href,
          bounds: bounds,
          sourceOrder: overlayOrder,
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

  void _reportUnpreservedPlacemarkContent(
    XmlElement placemark,
    String name,
    Map<String, _KmlStyle> styles,
    int sourceOrder,
    List<ImportIssue> issues,
  ) {
    final placemarkReference = _elementSourceReference(placemark);
    const supportedChildren = {
      'name',
      'styleUrl',
      'Style',
      'Point',
      'LineString',
      'Polygon',
      'MultiGeometry',
    };

    for (final child in placemark.childElements) {
      if (!supportedChildren.contains(child.localName)) {
        issues.add(
          ImportIssue(
            code: ImportIssueCode.unsupportedContent,
            severity: ImportIssueSeverity.error,
            message:
                '$placemarkReference contains ${child.localName}, which is not preserved.',
            sourceReference: placemarkReference,
            sourceOrder: sourceOrder,
          ),
        );
      }
    }

    const unsupportedGeometries = {'Track', 'MultiTrack', 'Model'};
    for (final element in placemark.descendantElements) {
      if (unsupportedGeometries.contains(element.localName)) {
        issues.add(
          ImportIssue(
            code: ImportIssueCode.unsupportedContent,
            severity: ImportIssueSeverity.error,
            message:
                '${_elementSourceReference(element)} is unsupported geometry content.',
            sourceReference: _elementSourceReference(element),
            sourceOrder: sourceOrder,
          ),
        );
      }
    }

    final styleUrl = _nonEmpty(_childText(placemark, 'styleUrl'));
    if (styleUrl != null) {
      final hash = styleUrl.lastIndexOf('#');
      final isLocalReference =
          styleUrl.startsWith('#') &&
          hash == 0 &&
          styles.containsKey(styleUrl.substring(1));
      if (!isLocalReference) {
        issues.add(
          ImportIssue(
            code: ImportIssueCode.unsupportedContent,
            severity: ImportIssueSeverity.warning,
            message:
                'Placemark "$name" has an unresolved or external style reference.',
            sourceReference: '$placemarkReference styleUrl="$styleUrl"',
            sourceOrder: sourceOrder,
          ),
        );
      }
    }
  }

  void _reportUnpreservedPlacemarkGeometryContent(
    XmlElement placemark,
    String name,
    int sourceOrder,
    List<ImportIssue> issues,
  ) {
    const supportedChildren = {
      'Point': {'coordinates'},
      'LineString': {'coordinates'},
      'LinearRing': {'coordinates'},
      'Polygon': {'outerBoundaryIs', 'innerBoundaryIs'},
      'outerBoundaryIs': {'LinearRing'},
      'innerBoundaryIs': {'LinearRing'},
      'MultiGeometry': {'Point', 'LineString', 'Polygon', 'MultiGeometry'},
    };

    for (final element in placemark.descendantElements) {
      final children = supportedChildren[element.localName];
      if (children == null) continue;

      for (final child in element.childElements) {
        if (children.contains(child.localName)) continue;
        issues.add(
          ImportIssue(
            code: ImportIssueCode.unsupportedContent,
            severity: ImportIssueSeverity.error,
            message:
                '${_elementSourceReference(child)} is not preserved by the geometry importer.',
            sourceReference: _elementSourceReference(child),
            sourceOrder: sourceOrder,
          ),
        );
      }
    }
  }

  void _reportUnpreservedDocumentContent(
    XmlDocument document,
    List<ImportIssue> issues,
  ) {
    const unpreservedElements = {
      'description',
      'ExtendedData',
      'Schema',
      'SchemaData',
      'Snippet',
      'TimeStamp',
      'TimeSpan',
      'NetworkLink',
      'PhotoOverlay',
      'ScreenOverlay',
      'Folder',
      'Model',
      'Track',
      'MultiTrack',
      'LookAt',
      'Camera',
      'Region',
      'visibility',
      'open',
      'address',
      'phoneNumber',
    };

    for (final element in document.descendantElements) {
      if (!unpreservedElements.contains(element.localName)) continue;
      if (_hasAncestorNamed(element, const {'Placemark', 'GroundOverlay'})) {
        continue;
      }
      issues.add(
        ImportIssue(
          code: ImportIssueCode.unsupportedContent,
          severity: ImportIssueSeverity.error,
          message:
              '${_elementSourceReference(element)} content is not preserved by the map model.',
          sourceReference: _elementSourceReference(element),
        ),
      );
    }

    const supportedContainerChildren = {
      'kml': {
        'Document',
        'Folder',
        'Placemark',
        'GroundOverlay',
        'NetworkLink',
        'PhotoOverlay',
        'ScreenOverlay',
      },
      'Document': {
        'name',
        'description',
        'visibility',
        'open',
        'address',
        'phoneNumber',
        'Snippet',
        'styleUrl',
        'Style',
        'StyleMap',
        'Schema',
        'Placemark',
        'Folder',
        'GroundOverlay',
        'NetworkLink',
        'PhotoOverlay',
        'ScreenOverlay',
        'LookAt',
        'Camera',
        'Region',
        'ExtendedData',
      },
      'Folder': {
        'name',
        'description',
        'visibility',
        'open',
        'address',
        'phoneNumber',
        'Snippet',
        'styleUrl',
        'Style',
        'StyleMap',
        'Schema',
        'Placemark',
        'Folder',
        'GroundOverlay',
        'NetworkLink',
        'PhotoOverlay',
        'ScreenOverlay',
        'LookAt',
        'Camera',
        'Region',
        'ExtendedData',
      },
    };

    for (final parent in document.descendantElements) {
      final supportedChildren = supportedContainerChildren[parent.localName];
      if (supportedChildren == null) continue;

      for (final child in parent.childElements) {
        if (supportedChildren.contains(child.localName)) continue;
        issues.add(
          ImportIssue(
            code: ImportIssueCode.unsupportedContent,
            severity: ImportIssueSeverity.error,
            message:
                '${_elementSourceReference(child)} is not supported in ${parent.localName}.',
            sourceReference: _elementSourceReference(child),
          ),
        );
      }
    }

    const supportedOverlayChildren = {
      'GroundOverlay': {
        'name',
        'visibility',
        'color',
        'drawOrder',
        'Icon',
        'LatLonBox',
        'altitude',
        'altitudeMode',
      },
      'Icon': {
        'href',
        'refreshMode',
        'refreshInterval',
        'viewRefreshMode',
        'viewRefreshTime',
        'viewBoundScale',
        'viewFormat',
        'httpQuery',
      },
      'LatLonBox': {'north', 'south', 'east', 'west', 'rotation'},
    };
    for (final parent in document.descendantElements) {
      final supportedChildren = supportedOverlayChildren[parent.localName];
      if (supportedChildren == null) continue;
      for (final child in parent.childElements) {
        if (supportedChildren.contains(child.localName)) continue;
        issues.add(
          ImportIssue(
            code: ImportIssueCode.unsupportedContent,
            severity: ImportIssueSeverity.error,
            message:
                '${_elementSourceReference(child)} is not preserved by GroundOverlay parsing.',
            sourceReference: _elementSourceReference(child),
          ),
        );
      }
    }
  }

  void _reportUnpreservedNonStyleAttributes(
    XmlDocument document,
    List<ImportIssue> issues,
  ) {
    const knownElements = {
      'kml',
      'Document',
      'Folder',
      'Placemark',
      'name',
      'visibility',
      'open',
      'address',
      'phoneNumber',
      'Snippet',
      'description',
      'styleUrl',
      'Style',
      'StyleMap',
      'Pair',
      'key',
      'LineStyle',
      'PolyStyle',
      'IconStyle',
      'LabelStyle',
      'BalloonStyle',
      'ListStyle',
      'color',
      'colorMode',
      'width',
      'fill',
      'outline',
      'scale',
      'heading',
      'hotSpot',
      'Icon',
      'href',
      'refreshMode',
      'refreshInterval',
      'viewRefreshMode',
      'viewRefreshTime',
      'viewBoundScale',
      'viewFormat',
      'httpQuery',
      'Point',
      'LineString',
      'LinearRing',
      'Polygon',
      'MultiGeometry',
      'coordinates',
      'extrude',
      'tessellate',
      'altitudeMode',
      'outerBoundaryIs',
      'innerBoundaryIs',
      'GroundOverlay',
      'drawOrder',
      'altitude',
      'LatLonBox',
      'north',
      'south',
      'east',
      'west',
      'rotation',
      'LookAt',
      'Camera',
      'longitude',
      'latitude',
      'range',
      'tilt',
      'Region',
      'Lod',
      'minLodPixels',
      'maxLodPixels',
      'minFadeExtent',
      'maxFadeExtent',
      'TimeStamp',
      'TimeSpan',
      'when',
      'begin',
      'end',
      'NetworkLink',
      'Link',
      'refreshVisibility',
      'flyToView',
      'ExtendedData',
      'Data',
      'value',
      'displayName',
      'Schema',
      'SchemaData',
      'SimpleData',
      'PhotoOverlay',
      'ScreenOverlay',
      'Model',
      'Location',
      'Orientation',
      'Scale',
      'ResourceMap',
      'Alias',
      'sourceHref',
      'targetHref',
      'Track',
      'MultiTrack',
      'coord',
      'angles',
      'author',
      'link',
    };

    for (final element in document.descendantElements) {
      final isStyleContent =
          element.localName == 'Style' ||
          element.localName == 'StyleMap' ||
          _hasAncestorNamed(element, const {'Style', 'StyleMap'});
      if (isStyleContent) continue;
      if (!knownElements.contains(element.localName)) {
        issues.add(
          ImportIssue(
            code: ImportIssueCode.unsupportedContent,
            severity: ImportIssueSeverity.error,
            message:
                '${_elementSourceReference(element)} is an unrecognized KML element and is not preserved.',
            sourceReference: _elementSourceReference(element),
          ),
        );
      }
      for (final attribute in element.attributes) {
        final name = attribute.name.local;
        if (name == 'xmlns' || attribute.name.prefix == 'xmlns') {
          continue;
        }
        if (name == 'id') {
          issues.add(
            ImportIssue(
              code: ImportIssueCode.unsupportedContent,
              severity: ImportIssueSeverity.error,
              message:
                  '${_elementSourceReference(element)} has an ID that is not retained by the imported map.',
              sourceReference: '${_elementSourceReference(element)} @id',
            ),
          );
          continue;
        }
        issues.add(
          ImportIssue(
            code: ImportIssueCode.unsupportedContent,
            severity: ImportIssueSeverity.error,
            message:
                '${_elementSourceReference(element)} has unsupported attribute "$name".',
            sourceReference: '${_elementSourceReference(element)} @$name',
          ),
        );
      }
    }
  }

  bool _hasAncestorNamed(XmlElement element, Set<String> names) {
    for (XmlNode? node = element.parent; node != null; node = node.parent) {
      if (node is XmlElement && names.contains(node.localName)) return true;
    }
    return false;
  }

  String _elementSourceReference(XmlElement element) {
    final path = <String>[];
    for (XmlNode? node = element; node is XmlElement; node = node.parent) {
      final id = node.getAttribute('id');
      final name = _nonEmpty(_childText(node, 'name'));
      final details = <String>[
        if (id != null && id.isNotEmpty) 'id="$id"',
        if (name != null) 'name="$name"',
      ];
      path.add(
        details.isEmpty
            ? node.localName
            : '${node.localName}(${details.join(', ')})',
      );
    }
    return path.reversed.join(' > ');
  }

  void _reportUnsupportedStyleContent(
    XmlDocument document,
    List<ImportIssue> issues,
  ) {
    final styleIds = document.descendantElements
        .where(
          (element) =>
              element.localName == 'Style' || element.localName == 'StyleMap',
        )
        .map((element) => element.getAttribute('id'))
        .whereType<String>()
        .toSet();

    void addIssue(XmlElement element, String message) {
      issues.add(
        ImportIssue(
          code: ImportIssueCode.unsupportedContent,
          severity: ImportIssueSeverity.warning,
          message: message,
          sourceReference: _elementSourceReference(element),
        ),
      );
    }

    for (final element in document.descendantElements.where(
      (element) =>
          element.localName == 'Style' ||
          element.localName == 'StyleMap' ||
          _hasAncestorNamed(element, const {'Style', 'StyleMap'}),
    )) {
      for (final attribute in element.attributes) {
        final name = attribute.name.local;
        if (name == 'id' ||
            name == 'xmlns' ||
            attribute.name.prefix == 'xmlns') {
          continue;
        }
        addIssue(
          element,
          '${element.localName} contains unsupported attribute "$name".',
        );
      }
    }

    for (final style in document.descendantElements.where(
      (element) => element.localName == 'Style',
    )) {
      for (final section in style.childElements) {
        final supportedProperties = switch (section.localName) {
          'LineStyle' => const {'color', 'width'},
          'PolyStyle' => const {'color', 'fill', 'outline'},
          'IconStyle' => const {'color'},
          _ => const <String>{},
        };
        if (supportedProperties.isEmpty) {
          addIssue(
            style,
            'Style contains unsupported ${section.localName} properties.',
          );
          continue;
        }

        for (final property in section.childElements) {
          if (!supportedProperties.contains(property.localName)) {
            addIssue(
              style,
              'Style contains unsupported ${section.localName}.${property.localName}.',
            );
            continue;
          }

          if (property.childElements.isNotEmpty) {
            addIssue(
              style,
              'Style contains nested content in ${section.localName}.${property.localName}.',
            );
          }

          final value = property.innerText.trim();
          if (property.localName == 'color' && _parseKmlColor(value) == null) {
            addIssue(style, 'Style contains an invalid color value.');
          } else if (property.localName == 'width') {
            final width = double.tryParse(value);
            if (width == null || !width.isFinite || width < 0) {
              addIssue(style, 'Style contains an invalid line width.');
            }
          } else if ((property.localName == 'fill' ||
                  property.localName == 'outline') &&
              !const {
                '0',
                '1',
                'false',
                'true',
              }.contains(value.toLowerCase())) {
            addIssue(
              style,
              'Style contains an invalid ${property.localName} value.',
            );
          }
        }
      }
    }

    for (final styleMap in document.descendantElements.where(
      (element) => element.localName == 'StyleMap',
    )) {
      for (final child in styleMap.childElements.where(
        (element) => element.localName != 'Pair',
      )) {
        addIssue(
          styleMap,
          'StyleMap contains unsupported ${child.localName} content.',
        );
      }
      for (final pair in styleMap.childElements.where(
        (element) => element.localName == 'Pair',
      )) {
        for (final child in pair.childElements.where(
          (element) =>
              !const {'key', 'styleUrl', 'Style'}.contains(element.localName),
        )) {
          addIssue(
            styleMap,
            'StyleMap Pair contains unsupported ${child.localName} content.',
          );
        }
        final key = _childText(pair, 'key');
        if (key != 'normal') {
          addIssue(
            styleMap,
            'StyleMap contains a non-normal Pair that is not preserved.',
          );
          continue;
        }

        final styleUrl = _nonEmpty(_childText(pair, 'styleUrl'));
        if (styleUrl != null &&
            (!styleUrl.startsWith('#') ||
                !styleIds.contains(styleUrl.substring(1)))) {
          addIssue(
            styleMap,
            'StyleMap contains an unresolved or external style reference.',
          );
        } else if (styleUrl == null && _firstChild(pair, 'Style') == null) {
          addIssue(styleMap, 'StyleMap normal Pair has no resolvable style.');
        }
      }
    }
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
  // ==========================================

  List<MapRasterOverlay> _loadOverlays(
    List<_OverlayRef> refs,
    _KmlSource source,
    List<ImportIssue> issues,
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
      void addOverlayIssue(ImportIssueCode code, String message) {
        issues.add(
          ImportIssue(
            code: code,
            severity: ImportIssueSeverity.error,
            message: message,
            sourceReference: ref.href,
            sourceOrder: ref.sourceOrder,
          ),
        );
      }

      if (asset == null) {
        addOverlayIssue(
          ImportIssueCode.missingOverlayAsset,
          'GroundOverlay image "${ref.href}" was not found in the source.',
        );
        continue;
      }

      if (asset.size > maxOverlayBytes ||
          totalBytes + asset.size > maxTotalOverlayBytes) {
        addOverlayIssue(
          ImportIssueCode.invalidOverlayImage,
          'GroundOverlay image "${ref.href}" exceeds the configured byte limit.',
        );
        continue;
      }

      final imageBytes = asset.readBytes();
      if (imageBytes == null) {
        addOverlayIssue(
          ImportIssueCode.missingOverlayAsset,
          'GroundOverlay image "${ref.href}" could not be read.',
        );
        continue;
      }

      totalBytes += imageBytes.length;
      if (imageBytes.length > maxOverlayBytes ||
          totalBytes > maxTotalOverlayBytes) {
        addOverlayIssue(
          ImportIssueCode.invalidOverlayImage,
          'GroundOverlay image "${ref.href}" exceeds the configured byte limit.',
        );
        continue;
      }

      final imageFormat = _imageFormat(imageBytes);
      final size = _readImageSize(imageBytes);
      if (imageFormat == null ||
          size == null ||
          size.width <= 0 ||
          size.height <= 0) {
        addOverlayIssue(
          ImportIssueCode.invalidOverlayImage,
          'GroundOverlay image "${ref.href}" is not a supported valid PNG, JPEG, or WebP.',
        );
        continue;
      }

      if (size.width > maxOverlayDimension ||
          size.height > maxOverlayDimension) {
        addOverlayIssue(
          ImportIssueCode.invalidOverlayImage,
          'GroundOverlay image "${ref.href}" exceeds the maximum dimensions.',
        );
        continue;
      }

      totalPixels += size.width * size.height;
      if (totalPixels > maxTotalOverlayPixels) {
        addOverlayIssue(
          ImportIssueCode.invalidOverlayImage,
          'GroundOverlay images exceed the total pixel limit.',
        );
        continue;
      }

      result.add(
        MapRasterOverlay(
          name: ref.name,
          bytes: imageBytes,
          bounds: LatLngBounds.fromPoints([
            LatLng(ref.bounds.north, ref.bounds.west),
            LatLng(ref.bounds.south, ref.bounds.east),
          ]),
          sourceBounds: ref.bounds,
        ),
      );
    }

    return result;
  }

  String? _imageFormat(Uint8List bytes) {
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47 &&
        bytes[4] == 0x0D &&
        bytes[5] == 0x0A &&
        bytes[6] == 0x1A &&
        bytes[7] == 0x0A) {
      return 'png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'jpg';
    }
    if (bytes.length >= 12 &&
        _matches(bytes, 0, 'RIFF') &&
        _matches(bytes, 8, 'WEBP')) {
      return 'webp';
    }
    return null;
  }

  ({int width, int height})? _readImageSize(Uint8List b) {
    if (b.length >= 24 &&
        b[0] == 0x89 &&
        b[1] == 0x50 &&
        b[2] == 0x4E &&
        b[3] == 0x47) {
      final w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      final h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
      return (width: w, height: h);
    }

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

    if (b.length > 30 && _matches(b, 0, 'RIFF') && _matches(b, 8, 'WEBP')) {
      if (_matches(b, 12, 'VP8X')) {
        final w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
        final h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
        return (width: w, height: h);
      }
      if (_matches(b, 12, 'VP8L') && b[20] == 0x2F) {
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return (
          width: (bits & 0x3FFF) + 1,
          height: ((bits >> 14) & 0x3FFF) + 1,
        );
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

  Stream<List<int>> _kmlByteChunks(
    Uint8List bytes, {
    int chunkSize = 64 * 1024,
  }) async* {
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = (offset + chunkSize < bytes.length)
          ? offset + chunkSize
          : bytes.length;

      yield bytes.sublist(offset, end);
    }
  }

  Future<void> _readXmlEvents(
    Uint8List bytes, {
    required void Function(XmlStartElementEvent event) onStartElement,
    required void Function(XmlEndElementEvent event) onEndElement,
    required void Function(XmlTextEvent event) onText,
  }) async {
    try {
      await _kmlByteChunks(bytes)
          .transform(utf8.decoder)
          .toXmlEvents(validateNesting: true, validateDocument: true)
          .normalizeEvents()
          .expand((events) => events)
          .forEachEvent(
            onStartElement: onStartElement,
            onEndElement: onEndElement,
            onText: onText,
          );
    } on XmlException catch (error) {
      throw FormatException('File KML tidak valid: ${error.message}');
    }
  }

  Future<Map<String, _KmlStyle>> _readStreamingStyles(Uint8List bytes) async {
    final styles = <String, _KmlStyle>{};

    var depth = 0;
    var styleDepth = -1;
    String? styleId;

    String? currentProperty;
    String? currentSection;
    final propertyValues = <String, String>{};

    String localName(String name) {
      final index = name.indexOf(':');
      return index == -1 ? name : name.substring(index + 1);
    }

    await _readXmlEvents(
      bytes,
      onStartElement: (event) {
        depth++;

        final name = localName(event.name);

        if (name == 'Style' && styleDepth == -1) {
          final idAttribute = event.attributes
              .where((attribute) => localName(attribute.name) == 'id')
              .firstOrNull;

          styleId = idAttribute?.value;

          if (styleId != null) {
            styleDepth = depth;
            propertyValues.clear();
          }
        } else if (styleDepth != -1 && depth == styleDepth + 1) {
          if (const {'LineStyle', 'PolyStyle', 'IconStyle'}.contains(name)) {
            currentSection = name;
          }
        } else if (styleDepth != -1 &&
            currentSection != null &&
            depth == styleDepth + 2) {
          currentProperty = name;
        }
      },
      onText: (event) {
        if (styleDepth == -1 || currentProperty == null) return;

        final value = event.value;
        if (value.trim().isEmpty) return;

        final key = '$currentSection.$currentProperty';
        propertyValues.update(
          key,
          (oldValue) => '$oldValue$value',
          ifAbsent: () => value,
        );
      },
      onEndElement: (event) {
        if (styleDepth != -1 && depth == styleDepth) {
          final style = _KmlStyle();

          final lineColor = propertyValues['LineStyle.color']?.trim();
          if (lineColor != null && lineColor.isNotEmpty) {
            style.lineColor = _parseKmlColor(lineColor);
          }

          final lineWidth = propertyValues['LineStyle.width']?.trim();
          if (lineWidth != null && lineWidth.isNotEmpty) {
            style.lineWidthExplicit = true;
            style.lineWidth = double.tryParse(lineWidth) ?? 3.0;
          }

          final polyColor = propertyValues['PolyStyle.color']?.trim();
          if (polyColor != null && polyColor.isNotEmpty) {
            style.polyColor = _parseKmlColor(polyColor);
          }

          final fill = propertyValues['PolyStyle.fill']?.trim();
          if (fill != null && _isFalse(fill)) {
            style.fillEnabled = false;
          }

          final outline = propertyValues['PolyStyle.outline']?.trim();
          if (outline != null && _isFalse(outline)) {
            style.outlineEnabled = false;
          }

          final iconColor = propertyValues['IconStyle.color']?.trim();
          if (iconColor != null && iconColor.isNotEmpty) {
            style.iconColor = _parseKmlColor(iconColor);
          }

          styles[styleId!] = style;

          styleId = null;
          styleDepth = -1;
          currentSection = null;
          currentProperty = null;
          propertyValues.clear();
        } else if (currentSection != null && depth == styleDepth + 1) {
          currentSection = null;
          currentProperty = null;
        } else if (currentProperty != null && depth == styleDepth + 2) {
          currentProperty = null;
        }

        depth--;
      },
    );

    return styles;
  }

  Future<Map<String, _StreamingStyleMapEntry>> _readStreamingStyleMaps(
    Uint8List bytes,
  ) async {
    final result = <String, _StreamingStyleMapEntry>{};

    String localName(String name) {
      final index = name.indexOf(':');
      return index == -1 ? name : name.substring(index + 1);
    }

    var depth = 0;
    var styleMapDepth = -1;
    var pairDepth = -1;
    var inlineStyleDepth = -1;

    String? styleMapId;
    String? pairKey;
    String? pairStyleUrl;

    String? currentSection;
    String? currentProperty;

    final inlineValues = <String, String>{};

    var textTarget = '';

    await _readXmlEvents(
      bytes,
      onStartElement: (event) {
        depth++;

        final name = localName(event.name);

        if (name == 'StyleMap' && styleMapDepth == -1) {
          final id = event.attributes
              .where((attribute) => localName(attribute.name) == 'id')
              .firstOrNull;

          styleMapId = id?.value;

          if (styleMapId != null) {
            styleMapDepth = depth;
          }
        } else if (styleMapDepth != -1 && pairDepth == -1 && name == 'Pair') {
          pairDepth = depth;
          pairKey = null;
          pairStyleUrl = null;
          inlineStyleDepth = -1;
          currentSection = null;
          currentProperty = null;
          inlineValues.clear();
        } else if (pairDepth != -1) {
          if (inlineStyleDepth == -1 && depth == pairDepth + 1) {
            if (name == 'key' || name == 'styleUrl') {
              textTarget = name;
            } else if (name == 'Style') {
              inlineStyleDepth = depth;
            }
          } else if (inlineStyleDepth != -1) {
            if (depth == inlineStyleDepth + 1 &&
                const {'LineStyle', 'PolyStyle', 'IconStyle'}.contains(name)) {
              currentSection = name;
            } else if (currentSection != null &&
                depth == inlineStyleDepth + 2) {
              currentProperty = name;
              textTarget = 'inline';
            }
          }
        }
      },
      onText: (event) {
        final value = event.value;

        if (textTarget == 'key') {
          pairKey = '${pairKey ?? ''}$value';
        } else if (textTarget == 'styleUrl') {
          pairStyleUrl = '${pairStyleUrl ?? ''}$value';
        } else if (textTarget == 'inline' &&
            currentSection != null &&
            currentProperty != null) {
          final key = '$currentSection.$currentProperty';

          inlineValues.update(
            key,
            (oldValue) => '$oldValue$value',
            ifAbsent: () => value,
          );
        }
      },
      onEndElement: (event) {
        final name = localName(event.name);

        if (pairDepth != -1 &&
            inlineStyleDepth != -1 &&
            depth == inlineStyleDepth) {
          inlineStyleDepth = -1;
          currentSection = null;
          currentProperty = null;
          textTarget = '';
        } else if (pairDepth != -1 &&
            inlineStyleDepth != -1 &&
            currentSection != null &&
            depth == inlineStyleDepth + 1) {
          currentSection = null;
          currentProperty = null;
          textTarget = '';
        } else if (pairDepth != -1 &&
            inlineStyleDepth != -1 &&
            currentProperty != null &&
            depth == inlineStyleDepth + 2) {
          currentProperty = null;
          textTarget = '';
        } else if (pairDepth != -1 &&
            inlineStyleDepth == -1 &&
            depth == pairDepth + 1 &&
            (name == 'key' || name == 'styleUrl')) {
          textTarget = '';
        }

        if (pairDepth != -1 && depth == pairDepth) {
          if (pairKey?.trim() == 'normal') {
            final inlineStyle = _KmlStyle();

            final lineColor = inlineValues['LineStyle.color']?.trim();
            if (lineColor != null && lineColor.isNotEmpty) {
              inlineStyle.lineColor = _parseKmlColor(lineColor);
            }

            final lineWidth = inlineValues['LineStyle.width']?.trim();
            if (lineWidth != null && lineWidth.isNotEmpty) {
              inlineStyle.lineWidthExplicit = true;
              inlineStyle.lineWidth = double.tryParse(lineWidth) ?? 3.0;
            }

            final polyColor = inlineValues['PolyStyle.color']?.trim();
            if (polyColor != null && polyColor.isNotEmpty) {
              inlineStyle.polyColor = _parseKmlColor(polyColor);
            }

            final fill = inlineValues['PolyStyle.fill']?.trim();
            if (fill != null && _isFalse(fill)) {
              inlineStyle.fillEnabled = false;
            }

            final outline = inlineValues['PolyStyle.outline']?.trim();
            if (outline != null && _isFalse(outline)) {
              inlineStyle.outlineEnabled = false;
            }

            final iconColor = inlineValues['IconStyle.color']?.trim();
            if (iconColor != null && iconColor.isNotEmpty) {
              inlineStyle.iconColor = _parseKmlColor(iconColor);
            }

            if (styleMapId != null) {
              result[styleMapId!] = _StreamingStyleMapEntry(
                styleUrl: pairStyleUrl?.trim(),
                inlineStyle: inlineValues.isEmpty ? null : inlineStyle,
              );
            }

            // Mengikuti perilaku parser lama:
            // hanya Pair normal pertama yang dipakai.
            pairDepth = -1;
            inlineStyleDepth = -1;
            currentSection = null;
            currentProperty = null;
            textTarget = '';
          } else {
            pairDepth = -1;
            inlineStyleDepth = -1;
            currentSection = null;
            currentProperty = null;
            textTarget = '';
          }
        }

        if (styleMapDepth != -1 && depth == styleMapDepth) {
          styleMapDepth = -1;
          styleMapId = null;
        }

        depth--;
      },
    );

    return result;
  }

  // ==========================================
  // XML & STYLE
  // ==========================================

  XmlDocument _parseXml(Uint8List data) {
    var text = utf8.decode(data, allowMalformed: true);

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
        result.lineWidthExplicit = true;
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
  // KEAMANAN ZIP (PREFLIGHT)
  // ==========================================

  void _preflightKmzZip(Uint8List bytes) {
    debugPrint('[KMZ PREFLIGHT] Mulai pemeriksaan ZIP');

    const eocdSignature = 0x06054b50;
    const centralHeaderSignature = 0x02014b50;
    const zip64ExtraId = 0x0001;
    const symlinkType = 0xA000;
    const maxZipCommentLength = 65535;
    const eocdMinLength = 22;

    if (bytes.length < eocdMinLength) {
      throw const FormatException(
        'File KMZ terlalu kecil atau bukan ZIP valid.',
      );
    }

    final data = ByteData.sublistView(bytes);

    int u16(int offset) => data.getUint16(offset, Endian.little);
    int u32(int offset) => data.getUint32(offset, Endian.little);

    final searchStart = bytes.length > eocdMinLength + maxZipCommentLength
        ? bytes.length - eocdMinLength - maxZipCommentLength
        : 0;

    var eocd = -1;

    for (var i = bytes.length - eocdMinLength; i >= searchStart; i--) {
      if (u32(i) == eocdSignature) {
        final commentLength = u16(i + 20);

        if (i + eocdMinLength + commentLength == bytes.length) {
          eocd = i;
          break;
        }
      }
    }

    if (eocd < 0) {
      throw const FormatException(
        'Struktur KMZ tidak valid: direktori akhir ZIP tidak ditemukan.',
      );
    }

    final diskNumber = u16(eocd + 4);
    final centralDisk = u16(eocd + 6);
    final entriesOnDisk = u16(eocd + 8);
    final totalEntries = u16(eocd + 10);
    final centralSize = u32(eocd + 12);
    final centralOffset = u32(eocd + 16);

    if (diskNumber != 0 || centralDisk != 0 || entriesOnDisk != totalEntries) {
      throw const FormatException('KMZ multi-disk tidak didukung.');
    }

    if (totalEntries == 0xFFFF ||
        centralSize == 0xFFFFFFFF ||
        centralOffset == 0xFFFFFFFF) {
      throw const FormatException('KMZ ZIP64 belum didukung.');
    }

    if (totalEntries > maxArchiveEntries) {
      throw FormatException(
        'KMZ memiliki terlalu banyak entri ($totalEntries). '
        'Batas: $maxArchiveEntries entri.',
      );
    }

    if (centralOffset > eocd ||
        centralSize > eocd - centralOffset ||
        centralOffset + centralSize != eocd) {
      throw const FormatException('Struktur direktori ZIP KMZ tidak valid.');
    }

    var cursor = centralOffset;
    final centralEnd = centralOffset + centralSize;

    for (var i = 0; i < totalEntries; i++) {
      if (cursor > centralEnd - 46 || u32(cursor) != centralHeaderSignature) {
        throw const FormatException('Entri direktori ZIP KMZ tidak valid.');
      }

      final versionMadeBy = u16(cursor + 4);
      final flags = u16(cursor + 8);
      final nameLength = u16(cursor + 28);
      final extraLength = u16(cursor + 30);
      final commentLength = u16(cursor + 32);
      final diskStart = u16(cursor + 34);
      final externalAttributes = u32(cursor + 38);
      final localHeaderOffset = u32(cursor + 42);

      final recordLength = 46 + nameLength + extraLength + commentLength;

      if (recordLength > centralEnd - cursor) {
        throw const FormatException('Panjang entri ZIP KMZ tidak valid.');
      }

      if (diskStart != 0 || localHeaderOffset == 0xFFFFFFFF) {
        throw const FormatException(
          'Entri ZIP multi-disk atau ZIP64 tidak didukung.',
        );
      }

      if ((flags & 0x0001) != 0) {
        throw const FormatException('KMZ terenkripsi tidak didukung.');
      }

      var extraCursor = cursor + 46 + nameLength;
      final extraEnd = extraCursor + extraLength;

      while (extraCursor < extraEnd) {
        if (extraEnd - extraCursor < 4) {
          throw const FormatException('Data tambahan ZIP KMZ tidak valid.');
        }

        final extraId = u16(extraCursor);
        final extraDataLength = u16(extraCursor + 2);
        extraCursor += 4;

        if (extraDataLength > extraEnd - extraCursor) {
          throw const FormatException(
            'Panjang data tambahan ZIP KMZ tidak valid.',
          );
        }

        if (extraId == zip64ExtraId) {
          throw const FormatException(
            'KMZ dengan ekstensi ZIP64 belum didukung.',
          );
        }

        extraCursor += extraDataLength;
      }

      final creatorSystem = versionMadeBy >> 8;
      final unixMode = externalAttributes >> 16;
      final fileType = unixMode & 0xF000;

      if (creatorSystem == 3 && fileType == symlinkType) {
        debugPrint('[KMZ PREFLIGHT] Symlink terdeteksi; KMZ ditolak');
        throw const FormatException(
          'KMZ berisi entri symbolic link yang tidak diizinkan.',
        );
      }

      cursor += recordLength;
    }

    if (cursor != centralEnd) {
      throw const FormatException('Ukuran direktori ZIP KMZ tidak cocok.');
    }

    debugPrint('[KMZ PREFLIGHT] Pemeriksaan selesai. ZIP aman.');
  }

  // ==========================================
  // PARSING FILE & GEOMETRI
  // ==========================================

  _KmlSource _readKmz(Uint8List bytes) {
    _preflightKmzZip(bytes);

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

    if (kmlFile.size > maxDocumentBytes) {
      throw FormatException(
        'Ukuran dokumen KML di dalam KMZ melebihi ${_mb(maxDocumentBytes)} MB.',
      );
    }

    final kmlBytes = kmlFile.readBytes() ?? Uint8List(0);

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

  bool _isJunkEntry(String path) {
    final normalized = path.replaceAll('\\', '/').toLowerCase();
    if (normalized.startsWith('__macosx/')) return true;
    return normalized.split('/').last.startsWith('._');
  }

  _ParsedCoordinates _coordinates(
    XmlElement element, {
    int maxAllowedCoordinates = KmlImportService.maxCoordinates,
    required List<ImportIssue> issues,
    required String sourceReference,
    required int sourceOrder,
  }) {
    if (maxAllowedCoordinates < 0) {
      throw const FormatException('Batas koordinat terlampaui.');
    }
    final coordinateElement = _firstDescendant(element, 'coordinates');
    if (coordinateElement == null) return const _ParsedCoordinates.empty();

    var text = coordinateElement.innerText.trim();
    if (text.isEmpty) return const _ParsedCoordinates.empty();

    if (_spaceAroundComma.hasMatch(text)) {
      text = text.replaceAll(_commaWithSpaces, ',');
    }

    final result = <LatLng>[];
    final altitudes = <double?>[];
    var invalidCoordinate = false;
    final length = text.length;
    var i = 0;

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
      if (firstComma <= 0) {
        invalidCoordinate = true;
        continue;
      }

      final secondComma = token.indexOf(',', firstComma + 1);
      if (secondComma != -1 && token.indexOf(',', secondComma + 1) != -1) {
        invalidCoordinate = true;
        continue;
      }
      final longitude = double.tryParse(token.substring(0, firstComma));
      final latitude = double.tryParse(
        token.substring(
          firstComma + 1,
          secondComma == -1 ? token.length : secondComma,
        ),
      );
      final altitude = secondComma == -1
          ? null
          : double.tryParse(token.substring(secondComma + 1));

      if (latitude == null ||
          longitude == null ||
          !latitude.isFinite ||
          !longitude.isFinite ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180 ||
          (secondComma != -1 && (altitude == null || !altitude.isFinite))) {
        invalidCoordinate = true;
        continue;
      }

      if (result.length >= maxAllowedCoordinates) {
        throw FormatException(
          'File terlalu kompleks: batas koordinat tersisa ($maxAllowedCoordinates) terlampaui. '
          'Sederhanakan atau pecah file ini.',
        );
      }
      result.add(LatLng(latitude, longitude));
      altitudes.add(altitude);
    }

    if (invalidCoordinate) {
      issues.add(
        ImportIssue(
          code: ImportIssueCode.invalidGeometryCoordinate,
          severity: ImportIssueSeverity.error,
          message:
              '$sourceReference contains invalid or out-of-range coordinates.',
          sourceReference: sourceReference,
          sourceOrder: sourceOrder,
        ),
      );
    }
    return _ParsedCoordinates(points: result, altitudes: altitudes);
  }

  MapOverlayBounds? _overlayBounds(XmlElement box) {
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

    return MapOverlayBounds(north: north, south: south, east: east, west: west);
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

  bool _isRemoteReference(String value) {
    final decoded = _safeDecode(value.trim());
    final uri = Uri.tryParse(decoded);
    return decoded.startsWith('//') || (uri?.hasScheme ?? false);
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
  bool lineWidthExplicit = false;
  bool fillEnabled = true;
  bool outlineEnabled = true;
}

class _StreamingStyleMapEntry {
  final String? styleUrl;
  final _KmlStyle? inlineStyle;

  const _StreamingStyleMapEntry({this.styleUrl, this.inlineStyle});
}

class _KmlMetadata {
  final Map<String, _KmlStyle> styles;
  final String documentName;

  const _KmlMetadata({required this.styles, required this.documentName});
}

class _KmlSource {
  Uint8List? _bytes;
  final Map<String, ArchiveFile> assets;
  final String baseDirectory;

  _KmlSource({
    required Uint8List this._bytes,
    required this.assets,
    required this.baseDirectory,
  });

  int get length => _bytes?.length ?? 0;

  Uint8List takeBytes() {
    final bytes = _bytes ?? Uint8List(0);
    _bytes = null;
    return bytes;
  }
}

class _OverlayRef {
  final String name;
  final String href;
  final MapOverlayBounds bounds;
  final int sourceOrder;

  const _OverlayRef({
    required this.name,
    required this.href,
    required this.bounds,
    required this.sourceOrder,
  });
}

class _ParsedCoordinates {
  final List<LatLng> points;
  final List<double?> altitudes;

  const _ParsedCoordinates({required this.points, required this.altitudes});

  const _ParsedCoordinates.empty() : points = const [], altitudes = const [];
}

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
