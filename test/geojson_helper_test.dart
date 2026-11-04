import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mmaps_flutter/models/imported_map.dart';
import 'package:mmaps_flutter/utils/geojson_helper.dart';

void main() {
  group('GeoJsonHelper tests', () {
    test('colorToHex converts Color to #RRGGBB correctly', () {
      expect(GeoJsonHelper.colorToHex(const Color(0xFFFF0000)), '#ff0000');
      expect(GeoJsonHelper.colorToHex(const Color(0xFF00FF00)), '#00ff00');
      expect(GeoJsonHelper.colorToHex(const Color(0xFF0000FF)), '#0000ff');
      expect(GeoJsonHelper.colorToHex(const Color(0x80123456)), '#123456');
    });

    test('colorToOpacity converts alpha to 0.0 - 1.0', () {
      expect(
        GeoJsonHelper.colorToOpacity(const Color(0xFF000000)),
        closeTo(1.0, 0.01),
      );
      expect(
        GeoJsonHelper.colorToOpacity(const Color(0x00000000)),
        closeTo(0.0, 0.01),
      );
      expect(
        GeoJsonHelper.colorToOpacity(const Color(0x80000000)),
        closeTo(0.5, 0.01),
      );
    });

    test('fromImportedMaps converts polygons with closed rings and [lon, lat] order', () {
      final map = ImportedMap(
        id: 'test-1',
        name: 'Test Area',
        fileName: 'test.kml',
        isActive: true,
        points: const [
          MapPointFeature(
            name: 'Pusat Titik',
            point: LatLng(-2.67, 118.89),
            color: Colors.red,
          ),
        ],
        lines: const [
          MapLineFeature(
            name: 'Jalan Utama',
            points: [LatLng(-2.67, 118.89), LatLng(-2.68, 118.90)],
            color: Colors.blue,
            width: 4,
          ),
        ],
        polygons: const [
          MapPolygonFeature(
            name: 'Kawasan Konservasi',
            points: [
              LatLng(-2.67, 118.89),
              LatLng(-2.67, 118.91),
              LatLng(-2.69, 118.90),
            ],
            holes: [],
            fillColor: Color(0x8000FF00),
            borderColor: Color(0xFF003300),
          ),
        ],
        overlays: [],
      );

      final collections = GeoJsonHelper.fromImportedMaps(
        [map],
        layerOpacities: const {'Test Area': 0.4},
        layerOutlines: const {'Test Area': true},
      );

      // Polygons
      final polyFeatures = collections.polygons['features'] as List;
      expect(polyFeatures.length, 1);
      final poly = polyFeatures.first as Map<String, dynamic>;
      expect(poly['geometry']['type'], 'Polygon');
      final rings = poly['geometry']['coordinates'] as List;
      final exterior = rings.first as List;
      // Linear ring must be closed (4 coordinates)
      expect(exterior.length, 4);
      // Coordinate format: [lon, lat]
      expect(exterior.first, [118.89, -2.67]);
      expect(exterior.last, [118.89, -2.67]);
      expect(poly['properties']['fillColor'], '#00ff00');
      expect(poly['properties']['borderColor'], '#003300');
      expect(poly['properties']['borderWidth'], 2.0);
      expect(poly['properties']['layerOpacity'], 0.4);

      // Lines
      final lineFeatures = collections.lines['features'] as List;
      expect(lineFeatures.length, 1);
      final line = lineFeatures.first as Map<String, dynamic>;
      expect(line['geometry']['type'], 'LineString');
      final lineCoords = line['geometry']['coordinates'] as List;
      expect(lineCoords.first, [118.89, -2.67]);
      expect(lineCoords.last, [118.90, -2.68]);
      expect(line['properties']['width'], 4);
      expect(line['properties']['layerOpacity'], 0.4);

      // Points
      final pointFeatures = collections.points['features'] as List;
      expect(pointFeatures.length, 1);
      final pt = pointFeatures.first as Map<String, dynamic>;
      expect(pt['geometry']['type'], 'Point');
      expect(pt['geometry']['coordinates'], [118.89, -2.67]);
      expect(pt['properties']['name'], 'Pusat Titik');
      expect(pt['properties']['layerOpacity'], 0.4);

      final defaultPolygons =
          GeoJsonHelper.fromImportedMaps([map]).polygons['features'] as List;
      final defaultPolygon = defaultPolygons.single as Map<String, dynamic>;
      expect(defaultPolygon['properties']['borderWidth'], 0.0);
      expect(defaultPolygon['properties']['layerOpacity'], 1.0);
    });

    test('preserves 2D and 3D coordinates in all GeoJSON conversion paths', () {
      final map = ImportedMap(
        id: 'dimensions',
        name: 'Dimensions',
        fileName: 'dimensions.kml',
        points: const [
          MapPointFeature(
            name: '2D point',
            point: LatLng(10, 20),
            color: Colors.red,
          ),
          MapPointFeature(
            name: '3D point',
            point: LatLng(11, 21),
            altitude: 0,
            color: Colors.red,
          ),
        ],
        lines: const [
          MapLineFeature(
            name: 'Mixed line',
            points: [LatLng(30, 40), LatLng(31, 41), LatLng(32, 42)],
            altitudes: [0, -5, null],
            color: Colors.blue,
          ),
        ],
        polygons: const [
          MapPolygonFeature(
            name: '3D polygon',
            points: [
              LatLng(1, 1),
              LatLng(4, 1),
              LatLng(4, 4),
              LatLng(1, 4),
              LatLng(1, 1),
            ],
            altitudes: [100, 101, 102, 103, 100],
            holes: [
              [
                LatLng(2, 2),
                LatLng(3, 2),
                LatLng(3, 3),
                LatLng(2, 3),
                LatLng(2, 2),
              ],
            ],
            holeAltitudes: [
              [0, -1, -2, -3, 0],
            ],
            fillColor: Colors.green,
            borderColor: Colors.black,
          ),
        ],
        overlays: const [],
      );

      expect(map.bounds!.southWest.longitude, 1);
      expect(map.bounds!.southWest.latitude, 1);
      expect(map.bounds!.northEast.longitude, 42);
      expect(map.bounds!.northEast.latitude, 32);

      final collections = GeoJsonHelper.fromImportedMaps([map]);
      final points = (collections.points['features'] as List)
          .cast<Map<String, dynamic>>();
      expect(points[0]['geometry']['coordinates'], [20.0, 10.0]);
      expect(points[1]['geometry']['coordinates'], [21.0, 11.0, 0.0]);

      final lines = (collections.lines['features'] as List)
          .cast<Map<String, dynamic>>();
      expect(lines.single['geometry']['coordinates'], [
        [40.0, 30.0, 0.0],
        [41.0, 31.0, -5.0],
        [42.0, 32.0],
      ]);

      final polygons = (collections.polygons['features'] as List)
          .cast<Map<String, dynamic>>();
      final rings = polygons.single['geometry']['coordinates'] as List;
      expect(rings[0].first, [1.0, 1.0, 100.0]);
      expect(rings[0].last, [1.0, 1.0, 100.0]);
      expect(rings[1], [
        [2.0, 2.0, 0.0],
        [2.0, 3.0, -1.0],
        [3.0, 3.0, -2.0],
        [3.0, 2.0, -3.0],
        [2.0, 2.0, 0.0],
      ]);

      final combined =
          GeoJsonHelper.importedMapToGeoJson(map)['features'] as List;
      expect(combined[0]['geometry']['coordinates'][0][0], [1.0, 1.0, 100.0]);
      expect(combined[1]['geometry']['coordinates'][1], [41.0, 31.0, -5.0]);
      expect(combined[3]['geometry']['coordinates'], [21.0, 11.0, 0.0]);
    });
  });
}
