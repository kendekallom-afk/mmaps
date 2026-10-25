import 'dart:convert';

class Basemap {
  final String id;
  final String name;
  final String? xyzUrl;

  const Basemap._({required this.id, required this.name, this.xyzUrl});

  static const openFreeMap = Basemap._(id: 'openfreemap', name: 'OpenFreeMap');

  factory Basemap.custom({
    required String id,
    required String name,
    required String xyzUrl,
  }) {
    return Basemap._(id: id, name: name, xyzUrl: xyzUrl);
  }

  bool get isCustom => xyzUrl != null;

  String get label => name;

  String get detail => isCustom ? xyzUrl! : 'Peta jalan';

  String? get attribution =>
      isCustom ? null : '© OpenFreeMap · © OpenStreetMap contributors';

  String get styleString {
    final url = xyzUrl;
    if (url == null) {
      return 'https://tiles.openfreemap.org/styles/liberty';
    }

    return '''
      {
        "version": 8,
        "sources": {
          "custom_xyz_source": {
            "type": "raster",
            "tiles": [${jsonEncode(url)}],
            "tileSize": 256
          }
        },
        "layers": [
          {
            "id": "custom_xyz_layer",
            "type": "raster",
            "source": "custom_xyz_source"
          }
        ]
      }
      ''';
  }

  Map<String, Object?> toMap() => {'id': id, 'name': name, 'xyzUrl': xyzUrl};

  factory Basemap.fromMap(Map<String, Object?> map) {
    return Basemap.custom(
      id: map['id']! as String,
      name: map['name']! as String,
      xyzUrl: map['xyzUrl']! as String,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Basemap &&
      other.id == id &&
      other.name == name &&
      other.xyzUrl == xyzUrl;

  @override
  int get hashCode => Object.hash(id, name, xyzUrl);
}
