/// Metadata for one folder-based map in the mMaps library.
///
/// This model deliberately contains no file-system or MapLibre dependencies.
class MapMeta {
  static const int currentFormatVersion = 1;

  static final RegExp _idPattern = RegExp(r'^[a-z0-9_][a-z0-9_-]{0,63}$');
  static const Set<String> _reservedIds = {
    '.tmp',
    '.deleting',
    'active_layers',
  };

  final String id;
  final int formatVersion;
  final String name;
  final String originalExtension;
  final DateTime importedAt;
  final int polygonCount;
  final int lineCount;
  final int pointCount;

  /// [minLon, minLat, maxLon, maxLat].
  final List<double> bounds;

  MapMeta({
    required this.id,
    required this.formatVersion,
    required this.name,
    required this.originalExtension,
    required this.importedAt,
    required this.polygonCount,
    required this.lineCount,
    required this.pointCount,
    required List<double> bounds,
  }) : bounds = List<double>.unmodifiable(bounds) {
    validate();
  }

  static bool isValidId(String value) {
    return _idPattern.hasMatch(value) && !_reservedIds.contains(value);
  }

  void validate() {
    if (!isValidId(id)) {
      throw FormatException('Invalid map ID: $id');
    }
    if (formatVersion < 1) {
      throw FormatException('Invalid formatVersion: $formatVersion');
    }
    if (name.trim().isEmpty) {
      throw const FormatException('Map name must not be empty');
    }
    if (originalExtension != 'kml' && originalExtension != 'kmz') {
      throw FormatException('Unsupported source extension: $originalExtension');
    }
    if (polygonCount < 0 || lineCount < 0 || pointCount < 0) {
      throw const FormatException('Feature counts must not be negative');
    }
    if (bounds.length != 4 || bounds.any((value) => !value.isFinite)) {
      throw const FormatException(
        'Bounds must contain four finite numbers: '
        '[minLon, minLat, maxLon, maxLat]',
      );
    }

    final minLon = bounds[0];
    final minLat = bounds[1];
    final maxLon = bounds[2];
    final maxLat = bounds[3];

    if (minLon < -180 ||
        maxLon > 180 ||
        minLat < -90 ||
        maxLat > 90 ||
        minLon > maxLon ||
        minLat > maxLat) {
      throw const FormatException('Bounds values or order are invalid');
    }
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'formatVersion': formatVersion,
        'name': name,
        'originalExtension': originalExtension,
        'importedAt': importedAt.toUtc().toIso8601String(),
        'featureCounts': {
          'polygons': polygonCount,
          'lines': lineCount,
          'points': pointCount,
        },
        'bounds': bounds,
      };

  factory MapMeta.fromJson(Map<String, dynamic> json) {
    final counts = json['featureCounts'];
    if (counts is! Map) {
      throw const FormatException('featureCounts must be an object');
    }

    final rawBounds = json['bounds'];
    if (rawBounds is! List || rawBounds.length != 4) {
      throw const FormatException(
        'bounds must be [minLon, minLat, maxLon, maxLat]',
      );
    }

    return MapMeta(
      id: _requiredString(json, 'id'),
      formatVersion: _requiredInt(json, 'formatVersion'),
      name: _requiredString(json, 'name'),
      originalExtension: _requiredString(json, 'originalExtension'),
      importedAt: DateTime.parse(_requiredString(json, 'importedAt')),
      polygonCount: _requiredInt(counts, 'polygons'),
      lineCount: _requiredInt(counts, 'lines'),
      pointCount: _requiredInt(counts, 'points'),
      bounds: rawBounds.map(_numberToDouble).toList(growable: false),
    );
  }

  static String _requiredString(Map<dynamic, dynamic> json, String key) {
    final value = json[key];
    if (value is! String) {
      throw FormatException('$key must be a string');
    }
    return value;
  }

  static int _requiredInt(Map<dynamic, dynamic> json, String key) {
    final value = json[key];
    if (value is! int) {
      throw FormatException('$key must be an integer');
    }
    return value;
  }

  static double _numberToDouble(dynamic value) {
    if (value is! num) {
      throw const FormatException('Each bounds value must be numeric');
    }
    return value.toDouble();
  }
}
