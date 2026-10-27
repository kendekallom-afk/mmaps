import 'dart:ui';

import 'package:latlong2/latlong.dart';

import '../models/imported_map.dart';

/// Container untuk FeatureCollection GeoJSON yang dipisahkan berdasarkan tipe geometri
class GeoJsonCollections {
  final Map<String, dynamic> polygons;
  final Map<String, dynamic> lines;
  final Map<String, dynamic> points;

  const GeoJsonCollections({
    required this.polygons,
    required this.lines,
    required this.points,
  });
}

/// Helper untuk mengonversi data ImportedMap (KML) ke format FeatureCollection GeoJSON
class GeoJsonHelper {
  /// Mengonversi objek [Color] ke string hex format '#RRGGBB'
  static String colorToHex(Color color) {
    final int argb = color.toARGB32();
    final String rgb = (argb & 0x00FFFFFF).toRadixString(16).padLeft(6, '0');
    return '#$rgb';
  }

  /// Mengekstrak nilai alpha/opacity dari [Color] (0.0 sampai 1.0)
  static double colorToOpacity(Color color) {
    final int argb = color.toARGB32();
    return ((argb >> 24) & 0xFF) / 255.0;
  }

  /// Memastikan linear ring poligon tertutup (first coordinate == last coordinate)
  /// dan memenuhi syarat GeoJSON RFC 7946 (minimal 4 koordinat).
  static List<List<double>> _closeLinearRing(List<LatLng> points) {
    if (points.isEmpty) return [];
    // Urutan koordinat GeoJSON: [longitude, latitude]
    final ring = points.map((p) => [p.longitude, p.latitude]).toList();
    if (ring.length >= 3) {
      if (ring.first[0] != ring.last[0] || ring.first[1] != ring.last[1]) {
        ring.add([ring.first[0], ring.first[1]]);
      }
    }
    return ring;
  }

  /// Mengonversi satu [ImportedMap] menjadi FeatureCollection GeoJSON gabungan
  static Map<String, dynamic> importedMapToGeoJson(ImportedMap map) {
    final features = <Map<String, dynamic>>[];

    // 1. Poligon
    for (final poly in map.polygons) {
      final exterior = _closeLinearRing(poly.points);
      if (exterior.length < 4) continue;

      final holes = poly.holes
          .map(_closeLinearRing)
          .where((ring) => ring.length >= 4)
          .toList();

      features.add({
        'type': 'Feature',
        'geometry': {
          'type': 'Polygon',
          'coordinates': [exterior, ...holes],
        },
        'properties': {
          'name': poly.name,
          'fillColor': colorToHex(poly.fillColor),
          'fillOpacity': colorToOpacity(poly.fillColor),
          'borderColor': colorToHex(poly.borderColor),
          'borderWidth': 0.0,
        },
      });
    }

    // 2. Garis
    for (final line in map.lines) {
      if (line.points.length < 2) continue;
      features.add({
        'type': 'Feature',
        'geometry': {
          'type': 'LineString',
          'coordinates': line.points
              .map((p) => [p.longitude, p.latitude])
              .toList(),
        },
        'properties': {
          'name': line.name,
          'color': colorToHex(line.color),
          'opacity': colorToOpacity(line.color),
          'width': line.width,
        },
      });
    }

    // 3. Titik
    for (final pt in map.points) {
      features.add({
        'type': 'Feature',
        'geometry': {
          'type': 'Point',
          'coordinates': [pt.point.longitude, pt.point.latitude],
        },
        'properties': {
          'name': pt.name,
          'color': colorToHex(pt.color),
          'opacity': colorToOpacity(pt.color),
          'radius': 6.0,
        },
      });
    }

    return {'type': 'FeatureCollection', 'features': features};
  }

  /// Mengonversi kumpulan [ImportedMap] aktif menjadi 3 FeatureCollection GeoJSON terpisah
  /// (Polygons, Lines, Points) agar dapat di-render secara optimal di MapLibre style layers.
  static GeoJsonCollections fromImportedMaps(
    Iterable<ImportedMap> maps, {
    Map<String, double> layerOpacities = const {},
    Map<String, bool> layerOutlines = const {},
  }) {
    final polygonFeatures = <Map<String, dynamic>>[];
    final lineFeatures = <Map<String, dynamic>>[];
    final pointFeatures = <Map<String, dynamic>>[];

    for (final map in maps) {
      // 1. Poligon
      for (final poly in map.polygons) {
        final exterior = _closeLinearRing(poly.points);
        if (exterior.length < 4) continue;

        final holes = poly.holes
            .map(_closeLinearRing)
            .where((ring) => ring.length >= 4)
            .toList();

        polygonFeatures.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Polygon',
            'coordinates': [exterior, ...holes],
          },
          'properties': {
            'name': poly.name,
            'fillColor': colorToHex(poly.fillColor),
            'fillOpacity': colorToOpacity(poly.fillColor),
            'borderColor': colorToHex(poly.borderColor),
            'borderWidth': layerOutlines[map.name] == true ? 2.0 : 0.0,
            'layerOpacity': layerOpacities[map.name] ?? 1.0,
          },
        });
      }

      // 2. Garis
      for (final line in map.lines) {
        if (line.points.length < 2) continue;
        lineFeatures.add({
          'type': 'Feature',
          'geometry': {
            'type': 'LineString',
            'coordinates': line.points
                .map((p) => [p.longitude, p.latitude])
                .toList(),
          },
          'properties': {
            'name': line.name,
            'color': colorToHex(line.color),
            'opacity': colorToOpacity(line.color),
            'width': line.width,
            'layerOpacity': layerOpacities[map.name] ?? 1.0,
          },
        });
      }

      // 3. Titik
      for (final pt in map.points) {
        pointFeatures.add({
          'type': 'Feature',
          'geometry': {
            'type': 'Point',
            'coordinates': [pt.point.longitude, pt.point.latitude],
          },
          'properties': {
            'name': pt.name,
            'color': colorToHex(pt.color),
            'opacity': colorToOpacity(pt.color),
            'radius': 6.0,
            'layerOpacity': layerOpacities[map.name] ?? 1.0,
          },
        });
      }
    }

    return GeoJsonCollections(
      polygons: {'type': 'FeatureCollection', 'features': polygonFeatures},
      lines: {'type': 'FeatureCollection', 'features': lineFeatures},
      points: {'type': 'FeatureCollection', 'features': pointFeatures},
    );
  }
}
