
/// Manifest seluruh GroundOverlay milik satu peta.
///
/// Model ini tidak bergantung pada Flutter MapLibre atau sistem file.
class MapOverlayManifest {
  final List<MapOverlayAsset> overlays;

  MapOverlayManifest({
    required List<MapOverlayAsset> overlays,
  }) : overlays = List.unmodifiable(overlays) {
    validate();
  }

  void validate() {
    final ids = <String>{};
    final filenames = <String>{};

    for (final overlay in overlays) {
      overlay.validate();

      if (!ids.add(overlay.id)) {
        throw FormatException(
          'Duplicate overlay ID: ${overlay.id}',
        );
      }

      if (!filenames.add(overlay.file)) {
        throw FormatException(
          'Duplicate overlay filename: ${overlay.file}',
        );
      }
    }
  }

  Map<String, dynamic> toJson() => {
        'overlays': overlays.map((item) => item.toJson()).toList(),
      };

  factory MapOverlayManifest.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawOverlays = json['overlays'];

    if (rawOverlays is! List) {
      throw const FormatException(
        'overlays must be an array',
      );
    }

    return MapOverlayManifest(
      overlays: rawOverlays.map((item) {
        if (item is! Map) {
          throw const FormatException(
            'Each overlay entry must be an object',
          );
        }

        return MapOverlayAsset.fromJson(
          Map<String, dynamic>.from(item),
        );
      }).toList(),
    );
  }
}

/// Metadata satu gambar GroundOverlay.
///
/// Nama file harus berupa basename yang dihasilkan importer,
/// bukan path dari KML/KMZ.
class MapOverlayAsset {
  static final RegExp _idPattern =
      RegExp(r'^overlay_[0-9]{4,}$');

  static final RegExp _filePattern =
      RegExp(r'^overlay_[0-9]{4,}\.(png|jpg|webp)$');

  final String id;
  final String name;
  final String file;
  final String imageFormat;
  final MapOverlayBounds bounds;

  const MapOverlayAsset({
    required this.id,
    required this.name,
    required this.file,
    required this.imageFormat,
    required this.bounds,
  });

  void validate() {
    if (!_idPattern.hasMatch(id)) {
      throw FormatException('Invalid overlay ID: $id');
    }

    if (!_filePattern.hasMatch(file)) {
      throw FormatException('Invalid overlay filename: $file');
    }

    if (name.trim().isEmpty) {
      throw const FormatException(
        'Overlay name must not be empty',
      );
    }

    if (!const {'png', 'jpg', 'webp'}.contains(imageFormat)) {
      throw FormatException(
        'Unsupported overlay image format: $imageFormat',
      );
    }

    final expectedExtension = '.$imageFormat';

    if (!file.endsWith(expectedExtension)) {
      throw FormatException(
        'Overlay filename and image format do not match',
      );
    }

    bounds.validate();
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'file': file,
        'imageFormat': imageFormat,
        'bounds': bounds.toJson(),
      };

  factory MapOverlayAsset.fromJson(
    Map<String, dynamic> json,
  ) {
    final rawBounds = json['bounds'];

    if (rawBounds is! Map) {
      throw const FormatException(
        'Overlay bounds must be an object',
      );
    }

    return MapOverlayAsset(
      id: _requiredString(json, 'id'),
      name: _requiredString(json, 'name'),
      file: _requiredString(json, 'file'),
      imageFormat: _requiredString(json, 'imageFormat'),
      bounds: MapOverlayBounds.fromJson(
        Map<String, dynamic>.from(rawBounds),
      ),
    );
  }

  static String _requiredString(
    Map<String, dynamic> json,
    String key,
  ) {
    final value = json[key];

    if (value is! String) {
      throw FormatException('$key must be a string');
    }

    return value;
  }
}

/// Batas geografis GroundOverlay.
///
/// Nilai disimpan langsung dari parser tanpa pembulatan.
class MapOverlayBounds {
  final double north;
  final double south;
  final double east;
  final double west;

  const MapOverlayBounds({
    required this.north,
    required this.south,
    required this.east,
    required this.west,
  });

  void validate() {
    final values = [north, south, east, west];

    if (values.any((value) => !value.isFinite)) {
      throw const FormatException(
        'Overlay bounds must contain finite numbers',
      );
    }

    if (north < -90 ||
        north > 90 ||
        south < -90 ||
        south > 90 ||
        east < -180 ||
        east > 180 ||
        west < -180 ||
        west > 180 ||
        north < south) {
      throw const FormatException(
        'Overlay geographic bounds are invalid',
      );
    }

    // east boleh lebih kecil dari west untuk mendukung
    // overlay yang melintasi garis tanggal internasional.
  }

  Map<String, dynamic> toJson() => {
        'north': north,
        'south': south,
        'east': east,
        'west': west,
      };

  factory MapOverlayBounds.fromJson(
    Map<String, dynamic> json,
  ) {
    return MapOverlayBounds(
      north: _numberToDouble(json, 'north'),
      south: _numberToDouble(json, 'south'),
      east: _numberToDouble(json, 'east'),
      west: _numberToDouble(json, 'west'),
    );
  }

  static double _numberToDouble(
    Map<String, dynamic> json,
    String key,
  ) {
    final value = json[key];

    if (value is! num) {
      throw FormatException(
        'Overlay bounds $key must be numeric',
      );
    }

    return value.toDouble();
  }
}
