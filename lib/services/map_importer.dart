import 'dart:convert';
import 'dart:typed_data';

import 'package:latlong2/latlong.dart';

import '../models/import_package.dart';
import '../models/imported_map.dart';
import '../models/map_meta.dart';
import '../models/map_overlay_manifest.dart';
import '../utils/geojson_helper.dart';
import 'kml_import_service.dart';
import 'overlay_image_validator.dart';

export '../models/import_package.dart';

class MapImporter {
  MapImporter({KmlImportService? parser, DateTime Function()? clock})
    : _parser = parser ?? KmlImportService(),
      _clock = clock ?? DateTime.now;

  final KmlImportService _parser;
  final DateTime Function() _clock;

  Future<ImportPackage> importMap({
    required Uint8List sourceBytes,
    required String sourceFileName,
    String? mapId,
    String? displayName,
    ImportProgressCallback? onProgress,
  }) async {
    var currentStage = ImportProgressStage.sourceValidation;

    void report(
      ImportProgressStage stage,
      ImportProgressStatus status,
      String message, {
      MapImportException? error,
    }) {
      onProgress?.call(
        ImportProgress(
          stage: stage,
          status: status,
          message: message,
          error: error,
        ),
      );
    }

    try {
      report(
        currentStage,
        ImportProgressStatus.inProgress,
        'Validating import input.',
      );
      final source = Uint8List.fromList(sourceBytes);
      final extension = _sourceExtension(sourceFileName);
      if (extension != 'kml' && extension != 'kmz') {
        throw MapImportInputException(
          'Source file must have a .kml or .kmz extension.',
        );
      }

      final importedAt = _clock().toUtc();
      final id = mapId ?? importedAt.microsecondsSinceEpoch.toString();
      if (!MapMeta.isValidId(id)) {
        throw MapImportInputException('Invalid map ID: $id');
      }
      report(
        currentStage,
        ImportProgressStatus.completed,
        'Import input is valid.',
      );

      currentStage = ImportProgressStage.parsing;
      report(
        currentStage,
        ImportProgressStatus.inProgress,
        'Parsing KML/KMZ source.',
      );
      final ImportParseResult parseResult;
      try {
        parseResult = _parser.parseWithIssues(
          id: id,
          fileName: _sourceBasename(sourceFileName),
          bytes: Uint8List.fromList(source),
        );
      } on FormatException catch (error, stackTrace) {
        throw MapImportParseException(
          'KML/KMZ parsing failed: ${error.message}',
          cause: error,
          stackTrace: stackTrace,
        );
      } catch (error, stackTrace) {
        throw MapImportParseException(
          'KML/KMZ parsing failed.',
          cause: error,
          stackTrace: stackTrace,
        );
      }

      final errors = parseResult.issues
          .where((issue) => issue.severity == ImportIssueSeverity.error)
          .toList(growable: false);
      if (errors.isNotEmpty) {
        throw MapImportContentException(
          'Import contains content that cannot be preserved.',
          issues: parseResult.issues,
        );
      }
      report(
        currentStage,
        ImportProgressStatus.completed,
        'KML/KMZ parsing completed.',
      );

      currentStage = ImportProgressStage.packageGeneration;
      report(
        currentStage,
        ImportProgressStatus.inProgress,
        'Generating import package.',
      );
      final map = parseResult.map;
      final geometry = _geometryGeoJson(map);
      final geometryCoordinates = _geometryCoordinates(map);
      final overlayAssets = <ImportOverlayAsset>[];
      final overlayEntries = <MapOverlayAsset>[];
      for (var i = 0; i < map.overlays.length; i++) {
        final overlay = map.overlays[i];
        final sourceBounds = overlay.sourceBounds;
        if (sourceBounds == null) {
          throw MapImportPackageException(
            'Overlay "${overlay.name}" has no parser-preserved source bounds.',
          );
        }

        final format = _detectImageFormat(overlay.bytes);
        if (format == null) {
          throw MapImportPackageException(
            'Overlay "${overlay.name}" has an unsupported image signature.',
          );
        }
        OverlayImageValidator.validate(format, overlay.bytes);

        final number = (i + 1).toString().padLeft(4, '0');
        final file = 'overlay_$number.$format';
        final id = 'overlay_$number';
        overlayEntries.add(
          MapOverlayAsset(
            id: id,
            name: overlay.name.trim().isEmpty
                ? 'GroundOverlay ${i + 1}'
                : overlay.name,
            file: file,
            imageFormat: format,
            bounds: sourceBounds,
          ),
        );
        overlayAssets.add(
          ImportOverlayAsset(
            file: file,
            imageFormat: format,
            bytes: overlay.bytes,
          ),
        );
      }

      final bounds = geometryCoordinates.isNotEmpty
          ? _geometryBounds(geometryCoordinates)
          : _overlayBounds(overlayEntries);
      if (bounds == null) {
        throw MapImportPackageException(
          'Map metadata bounds require vector geometry or a valid GroundOverlay.',
        );
      }

      final name = _mapName(displayName, map.name, sourceFileName);
      final metadata = MapMeta(
        id: id,
        formatVersion: MapMeta.currentFormatVersion,
        name: name,
        originalExtension: extension,
        importedAt: importedAt,
        polygonCount: _featureCount(geometry.polygons),
        lineCount: _featureCount(geometry.lines),
        pointCount: _featureCount(geometry.points),
        bounds: bounds,
      );

      final package = ImportPackage(
        metadata: metadata,
        originalSource: OriginalMapSource(extension: extension, bytes: source),
        geoJson: geometry,
        layerStyleJson: _defaultLayerStyleJson,
        overlayManifest: MapOverlayManifest(overlays: overlayEntries),
        overlayAssets: overlayAssets,
        parserIssues: parseResult.issues,
      );
      report(
        currentStage,
        ImportProgressStatus.completed,
        'Import package generated.',
      );

      currentStage = ImportProgressStage.packageValidation;
      report(
        currentStage,
        ImportProgressStatus.inProgress,
        'Validating import package.',
      );
      package.validate();
      report(
        currentStage,
        ImportProgressStatus.completed,
        'Import package is valid.',
      );
      report(
        ImportProgressStage.complete,
        ImportProgressStatus.completed,
        'Import package is ready.',
      );
      return package;
    } on MapImportException catch (error) {
      report(
        currentStage,
        ImportProgressStatus.failed,
        error.message,
        error: error,
      );
      rethrow;
    } on FormatException catch (error, stackTrace) {
      final wrapped = MapImportPackageException(
        error.message,
        cause: error,
        stackTrace: stackTrace,
      );
      report(
        currentStage,
        ImportProgressStatus.failed,
        wrapped.message,
        error: wrapped,
      );
      throw wrapped;
    } catch (error, stackTrace) {
      final wrapped = MapImportPackageException(
        'Could not build a valid import package.',
        cause: error,
        stackTrace: stackTrace,
      );
      report(
        currentStage,
        ImportProgressStatus.failed,
        wrapped.message,
        error: wrapped,
      );
      throw wrapped;
    }
  }

  static const String _defaultLayerStyleJson = '''
{
  "version": 1,
  "source": "mMaps-application-defaults",
  "polygon": {
    "borderWidth": 0.0,
    "layerOpacity": 1.0
  },
  "line": {
    "layerOpacity": 1.0
  },
  "point": {
    "radius": 6.0,
    "layerOpacity": 1.0,
    "strokeColor": "#FFFFFF",
    "strokeWidth": 1.5
  }
}
''';

  MapGeometryGeoJson _geometryGeoJson(ImportedMap map) {
    final polygons = <Map<String, dynamic>>[];
    for (final polygon in map.polygons) {
      if (polygon.holeAltitudes.isNotEmpty &&
          polygon.holeAltitudes.length != polygon.holes.length) {
        throw MapImportPackageException(
          'A polygon feature has altitude data that does not match its interior rings.',
        );
      }
      final rings = <List<List<double>>>[
        _polygonRing(
          polygon.points,
          polygon.altitudes,
          'polygon exterior ring',
        ),
        for (var i = 0; i < polygon.holes.length; i++)
          _polygonRing(
            polygon.holes[i],
            polygon.holeAltitudes.isEmpty ? const [] : polygon.holeAltitudes[i],
            'polygon interior ring',
          ),
      ];
      polygons.add({
        'type': 'Feature',
        'geometry': {'type': 'Polygon', 'coordinates': rings},
        'properties': {
          'name': polygon.name,
          'fillColor': GeoJsonHelper.colorToHex(polygon.fillColor),
          'fillOpacity': GeoJsonHelper.colorToOpacity(polygon.fillColor),
          'borderColor': GeoJsonHelper.colorToHex(polygon.borderColor),
          'borderOpacity': GeoJsonHelper.colorToOpacity(polygon.borderColor),
          'borderWidth': 0.0,
          'layerOpacity': 1.0,
        },
      });
    }

    final lines = map.lines
        .map((line) {
          if (line.points.length < 2) {
            throw MapImportPackageException(
              'A line feature contains fewer than two coordinates.',
            );
          }
          return {
            'type': 'Feature',
            'geometry': {
              'type': 'LineString',
              'coordinates': _coordinateSequence(
                line.points,
                line.altitudes,
                'line',
              ),
            },
            'properties': {
              'name': line.name,
              'color': GeoJsonHelper.colorToHex(line.color),
              'opacity': GeoJsonHelper.colorToOpacity(line.color),
              'width': line.width,
              'layerOpacity': 1.0,
            },
          };
        })
        .toList(growable: false);

    final points = map.points
        .map((point) {
          return {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': _coordinate(point.point, point.altitude),
            },
            'properties': {
              'name': point.name,
              'color': GeoJsonHelper.colorToHex(point.color),
              'opacity': GeoJsonHelper.colorToOpacity(point.color),
              'radius': 6.0,
              'layerOpacity': 1.0,
            },
          };
        })
        .toList(growable: false);

    return MapGeometryGeoJson(
      polygons: jsonEncode({'type': 'FeatureCollection', 'features': polygons}),
      lines: jsonEncode({'type': 'FeatureCollection', 'features': lines}),
      points: jsonEncode({'type': 'FeatureCollection', 'features': points}),
    );
  }

  List<double> _coordinate(LatLng coordinate, [double? altitude]) {
    if (altitude != null && !altitude.isFinite) {
      throw MapImportPackageException(
        'A geometry coordinate has a non-finite altitude.',
      );
    }
    return [coordinate.longitude, coordinate.latitude, ?altitude];
  }

  List<List<double>> _coordinateSequence(
    List<LatLng> coordinates,
    List<double?> altitudes,
    String label,
  ) {
    if (altitudes.isNotEmpty && altitudes.length != coordinates.length) {
      throw MapImportPackageException(
        'A $label feature has altitude data that does not match its coordinates.',
      );
    }
    return [
      for (var i = 0; i < coordinates.length; i++)
        _coordinate(coordinates[i], altitudes.isEmpty ? null : altitudes[i]),
    ];
  }

  List<List<double>> _polygonRing(
    List<LatLng> ring,
    List<double?> altitudes,
    String label,
  ) {
    if (ring.length < 4 ||
        ring.first.latitude != ring.last.latitude ||
        ring.first.longitude != ring.last.longitude) {
      throw MapImportPackageException(
        '$label is not a closed GeoJSON linear ring; coordinates were not changed.',
      );
    }
    final coordinates = _coordinateSequence(ring, altitudes, label);
    final first = coordinates.first;
    final last = coordinates.last;
    if (first.length != last.length ||
        List<int>.generate(
          first.length,
          (index) => index,
        ).any((index) => first[index] != last[index])) {
      throw MapImportPackageException(
        '$label has different first and last positions; coordinates were not changed.',
      );
    }
    return coordinates;
  }

  List<LatLng> _geometryCoordinates(ImportedMap map) => [
    ...map.points.map((feature) => feature.point),
    ...map.lines.expand((feature) => feature.points),
    ...map.polygons.expand(
      (feature) => [...feature.points, ...feature.holes.expand((ring) => ring)],
    ),
  ];

  List<double> _geometryBounds(List<LatLng> coordinates) {
    var minLongitude = coordinates.first.longitude;
    var maxLongitude = minLongitude;
    var minLatitude = coordinates.first.latitude;
    var maxLatitude = minLatitude;

    for (final coordinate in coordinates.skip(1)) {
      if (coordinate.longitude < minLongitude) {
        minLongitude = coordinate.longitude;
      }
      if (coordinate.longitude > maxLongitude) {
        maxLongitude = coordinate.longitude;
      }
      if (coordinate.latitude < minLatitude) {
        minLatitude = coordinate.latitude;
      }
      if (coordinate.latitude > maxLatitude) {
        maxLatitude = coordinate.latitude;
      }
    }

    // Vector bounds ignore altitude and use numeric, non-wrapped lon/lat min/max.
    return [minLongitude, minLatitude, maxLongitude, maxLatitude];
  }

  List<double>? _overlayBounds(List<MapOverlayAsset> overlays) {
    if (overlays.isEmpty) return null;

    var minLongitude = double.infinity;
    var minLatitude = double.infinity;
    var maxLongitude = double.negativeInfinity;
    var maxLatitude = double.negativeInfinity;
    for (final overlay in overlays) {
      final bounds = overlay.bounds;
      final west = bounds.west < bounds.east ? bounds.west : bounds.east;
      final east = bounds.west > bounds.east ? bounds.west : bounds.east;
      if (west < minLongitude) minLongitude = west;
      if (east > maxLongitude) maxLongitude = east;
      if (bounds.south < minLatitude) minLatitude = bounds.south;
      if (bounds.north > maxLatitude) maxLatitude = bounds.north;
    }

    // Raster-only metadata uses overlay lon/lat and a numeric, non-wrapped
    // envelope; vector bounds take precedence when vector geometry exists.
    return [minLongitude, minLatitude, maxLongitude, maxLatitude];
  }

  int _featureCount(String featureCollection) {
    final decoded = jsonDecode(featureCollection) as Map<String, dynamic>;
    return (decoded['features'] as List<dynamic>).length;
  }

  String _sourceExtension(String fileName) {
    final basename = _sourceBasename(fileName);
    final dot = basename.lastIndexOf('.');
    return dot < 0 ? '' : basename.substring(dot + 1).toLowerCase();
  }

  String _sourceBasename(String fileName) =>
      fileName.replaceAll('\\', '/').split('/').last;

  String _mapName(String? displayName, String parsedName, String fileName) {
    final supplied = displayName?.trim();
    if (supplied != null && supplied.isNotEmpty) return supplied;
    final parsed = parsedName.trim();
    if (parsed.isNotEmpty) return parsed;

    final basename = _sourceBasename(fileName);
    final dot = basename.lastIndexOf('.');
    final fallback = (dot > 0 ? basename.substring(0, dot) : basename).trim();
    if (fallback.isEmpty) {
      throw MapImportInputException('A non-empty map name is required.');
    }
    return fallback;
  }

  String? _detectImageFormat(Uint8List bytes) {
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
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46 &&
        bytes[8] == 0x57 &&
        bytes[9] == 0x45 &&
        bytes[10] == 0x42 &&
        bytes[11] == 0x50) {
      return 'webp';
    }
    return null;
  }
}
