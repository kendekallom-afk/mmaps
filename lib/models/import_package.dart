import 'dart:convert';
import 'dart:typed_data';

import 'imported_map.dart';
import 'map_meta.dart';
import 'map_overlay_manifest.dart';
import '../services/overlay_image_validator.dart';

class OriginalMapSource {
  final String extension;
  final Uint8List _bytes;

  OriginalMapSource({required this.extension, required Uint8List bytes})
    : _bytes = Uint8List.fromList(bytes) {
    if (extension != 'kml' && extension != 'kmz') {
      throw FormatException('Unsupported source extension: $extension');
    }
  }

  Uint8List get bytes => Uint8List.fromList(_bytes);
}

class MapGeometryGeoJson {
  final String polygons;
  final String lines;
  final String points;

  const MapGeometryGeoJson({
    required this.polygons,
    required this.lines,
    required this.points,
  });
}

class ImportOverlayAsset {
  final String file;
  final String imageFormat;
  final Uint8List _bytes;

  ImportOverlayAsset({
    required this.file,
    required this.imageFormat,
    required Uint8List bytes,
  }) : _bytes = Uint8List.fromList(bytes);

  Uint8List get bytes => Uint8List.fromList(_bytes);
}

class ImportPackage {
  final MapMeta metadata;
  final OriginalMapSource originalSource;
  final MapGeometryGeoJson geoJson;
  final String layerStyleJson;
  final MapOverlayManifest overlayManifest;
  final List<ImportOverlayAsset> overlayAssets;
  final List<ImportIssue> parserIssues;

  ImportPackage({
    required this.metadata,
    required this.originalSource,
    required this.geoJson,
    required this.layerStyleJson,
    required this.overlayManifest,
    required List<ImportOverlayAsset> overlayAssets,
    List<ImportIssue> parserIssues = const [],
  }) : overlayAssets = List.unmodifiable(overlayAssets),
       parserIssues = List.unmodifiable(parserIssues) {
    validate();
  }

  List<ImportIssue> get warnings => List.unmodifiable(
    parserIssues.where(
      (issue) => issue.severity == ImportIssueSeverity.warning,
    ),
  );

  void validate() {
    metadata.validate();
    overlayManifest.validate();

    if (metadata.originalExtension != originalSource.extension) {
      throw const FormatException(
        'Metadata source extension does not match the original source',
      );
    }

    final polygonFeatures = _readFeatureCollection(
      geoJson.polygons,
      'polygons',
    );
    final lineFeatures = _readFeatureCollection(geoJson.lines, 'lines');
    final pointFeatures = _readFeatureCollection(geoJson.points, 'points');
    final coordinates = <List<double>>[];
    _validateGeometryFeatures(polygonFeatures, 'Polygon', coordinates);
    _validateGeometryFeatures(lineFeatures, 'LineString', coordinates);
    _validateGeometryFeatures(pointFeatures, 'Point', coordinates);

    if (polygonFeatures.length != metadata.polygonCount ||
        lineFeatures.length != metadata.lineCount ||
        pointFeatures.length != metadata.pointCount) {
      throw const FormatException(
        'GeoJSON feature counts do not match map metadata',
      );
    }
    final style = jsonDecode(layerStyleJson);
    if (style is! Map<String, dynamic>) {
      throw const FormatException(
        'layer_style.json must contain a JSON object',
      );
    }

    final manifestAssets = <String, MapOverlayAsset>{
      for (final overlay in overlayManifest.overlays) overlay.file: overlay,
    };
    final packageAssets = <String, ImportOverlayAsset>{};

    for (final asset in overlayAssets) {
      if (packageAssets.containsKey(asset.file)) {
        throw FormatException('Duplicate overlay asset: ${asset.file}');
      }

      final manifestEntry = manifestAssets[asset.file];
      if (manifestEntry == null) {
        throw FormatException(
          'Overlay asset is not registered in the manifest: ${asset.file}',
        );
      }
      if (asset.imageFormat != manifestEntry.imageFormat) {
        throw FormatException(
          'Overlay asset format does not match the manifest: ${asset.file}',
        );
      }
      OverlayImageValidator.validate(asset.imageFormat, asset.bytes);
      packageAssets[asset.file] = asset;
    }

    if (packageAssets.length != manifestAssets.length) {
      throw const FormatException(
        'Every overlay manifest entry must have exactly one image asset',
      );
    }

    // Bounds use vector coordinates when present; otherwise, valid overlays
    // supply a numeric, non-wrapped longitude/latitude envelope. Altitude is
    // excluded. Wrapped antimeridian bounds are not represented in this format.
    final expectedBounds = coordinates.isNotEmpty
        ? _vectorBounds(coordinates)
        : _overlayBounds(overlayManifest.overlays);
    if (expectedBounds == null) {
      throw const FormatException(
        'An import package must contain vector geometry or a valid raster overlay',
      );
    }

    if (!_sameBounds(metadata.bounds, expectedBounds)) {
      throw const FormatException(
        'Metadata bounds do not match the package geometry or overlay bounds',
      );
    }
  }

  static List<double> _vectorBounds(List<List<double>> coordinates) {
    final minLongitude = coordinates
        .map((coordinate) => coordinate[0])
        .reduce((a, b) => a < b ? a : b);
    final maxLongitude = coordinates
        .map((coordinate) => coordinate[0])
        .reduce((a, b) => a > b ? a : b);
    final minLatitude = coordinates
        .map((coordinate) => coordinate[1])
        .reduce((a, b) => a < b ? a : b);
    final maxLatitude = coordinates
        .map((coordinate) => coordinate[1])
        .reduce((a, b) => a > b ? a : b);
    return [minLongitude, minLatitude, maxLongitude, maxLatitude];
  }

  static List<double>? _overlayBounds(List<MapOverlayAsset> overlays) {
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
    return [minLongitude, minLatitude, maxLongitude, maxLatitude];
  }

  static bool _sameBounds(List<double> actual, List<double> expected) {
    for (var i = 0; i < actual.length; i++) {
      if (actual[i] != expected[i]) return false;
    }
    return true;
  }

  static List<dynamic> _readFeatureCollection(String content, String name) {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic> ||
        decoded['type'] != 'FeatureCollection' ||
        decoded['features'] is! List) {
      throw FormatException(
        '$name GeoJSON must be a FeatureCollection with a features array',
      );
    }
    return decoded['features'] as List<dynamic>;
  }

  static void _validateGeometryFeatures(
    List<dynamic> features,
    String expectedGeometry,
    List<List<double>> coordinates,
  ) {
    for (final feature in features) {
      if (feature is! Map<String, dynamic> ||
          feature['type'] != 'Feature' ||
          feature['geometry'] is! Map<String, dynamic> ||
          (feature['geometry'] as Map<String, dynamic>)['type'] !=
              expectedGeometry) {
        throw FormatException(
          'Expected GeoJSON Feature with $expectedGeometry geometry',
        );
      }

      final geometry = feature['geometry'] as Map<String, dynamic>;
      final rawCoordinates = geometry['coordinates'];
      switch (expectedGeometry) {
        case 'Point':
          coordinates.add(_position(rawCoordinates));
        case 'LineString':
          final line = _coordinateList(rawCoordinates);
          if (line.length < 2) {
            throw const FormatException(
              'GeoJSON LineString must contain at least two coordinates',
            );
          }
          coordinates.addAll(line);
        case 'Polygon':
          if (rawCoordinates is! List || rawCoordinates.isEmpty) {
            throw const FormatException(
              'GeoJSON Polygon must contain an exterior ring',
            );
          }
          for (final rawRing in rawCoordinates) {
            final ring = _coordinateList(rawRing);
            if (ring.length < 4 || !_samePosition(ring.first, ring.last)) {
              throw const FormatException(
                'GeoJSON Polygon rings must be closed and contain at least four coordinates',
              );
            }
            coordinates.addAll(ring);
          }
      }
    }
  }

  static List<List<double>> _coordinateList(dynamic rawCoordinates) {
    if (rawCoordinates is! List) {
      throw const FormatException('GeoJSON coordinates must be an array');
    }
    return rawCoordinates.map(_position).toList(growable: false);
  }

  static List<double> _position(dynamic rawPosition) {
    if (rawPosition is! List ||
        (rawPosition.length != 2 && rawPosition.length != 3)) {
      throw const FormatException(
        'GeoJSON positions must contain [longitude, latitude] or [longitude, latitude, altitude]',
      );
    }
    final longitude = rawPosition[0];
    final latitude = rawPosition[1];
    final altitude = rawPosition.length == 3 ? rawPosition[2] : null;
    if (longitude is! num ||
        latitude is! num ||
        !longitude.isFinite ||
        !latitude.isFinite ||
        longitude < -180 ||
        longitude > 180 ||
        latitude < -90 ||
        latitude > 90 ||
        (altitude != null && (altitude is! num || !altitude.isFinite))) {
      throw const FormatException('GeoJSON position is out of range');
    }
    return [
      longitude.toDouble(),
      latitude.toDouble(),
      if (altitude != null) (altitude as num).toDouble(),
    ];
  }

  static bool _samePosition(List<double> first, List<double> last) {
    if (first.length != last.length) return false;
    for (var i = 0; i < first.length; i++) {
      if (first[i] != last[i]) return false;
    }
    return true;
  }
}

enum ImportIssueSeverity { warning, error }

enum ImportIssueCode {
  unsupportedContent,
  remoteOverlayReference,
  missingOverlayReference,
  missingOverlayBounds,
  invalidOverlayBounds,
  unsupportedOverlayBehavior,
  missingOverlayAsset,
  invalidOverlayImage,
  invalidGeometryCoordinate,
  unsupportedGeometryAltitude,
  invalidGeometry,
  noRenderableContent,
}

class ImportIssue {
  final ImportIssueCode code;
  final ImportIssueSeverity severity;
  final String message;
  final String? sourceReference;
  final int? sourceOrder;

  const ImportIssue({
    required this.code,
    required this.severity,
    required this.message,
    this.sourceReference,
    this.sourceOrder,
  });
}

class ImportParseResult {
  final ImportedMap map;
  final List<ImportIssue> issues;

  ImportParseResult({required this.map, required List<ImportIssue> issues})
    : issues = List.unmodifiable(issues);

  bool get hasErrors =>
      issues.any((issue) => issue.severity == ImportIssueSeverity.error);
}

abstract class MapImportException implements Exception {
  final String message;
  final Object? cause;
  final StackTrace? stackTrace;
  final List<ImportIssue> issues;

  MapImportException(
    this.message, {
    this.cause,
    this.stackTrace,
    List<ImportIssue> issues = const [],
  }) : issues = List.unmodifiable(issues);

  @override
  String toString() => message;
}

class MapImportInputException extends MapImportException {
  MapImportInputException(super.message, {super.cause, super.stackTrace});
}

class MapImportParseException extends MapImportException {
  MapImportParseException(super.message, {super.cause, super.stackTrace});
}

class MapImportContentException extends MapImportException {
  MapImportContentException(
    super.message, {
    required super.issues,
    super.cause,
    super.stackTrace,
  });
}

class MapImportPackageException extends MapImportException {
  MapImportPackageException(super.message, {super.cause, super.stackTrace});
}

enum ImportProgressStage {
  sourceValidation,
  parsing,
  packageGeneration,
  packageValidation,
  complete,
}

enum ImportProgressStatus { inProgress, completed, failed }

class ImportProgress {
  final ImportProgressStage stage;
  final ImportProgressStatus status;
  final String message;
  final MapImportException? error;

  const ImportProgress({
    required this.stage,
    required this.status,
    required this.message,
    this.error,
  });
}

typedef ImportProgressCallback = void Function(ImportProgress progress);
