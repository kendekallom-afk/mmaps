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
            points: [
              LatLng(-2.67, 118.89),
              LatLng(-2.68, 118.90),
            ],
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

      final collections = GeoJsonHelper.fromImportedMaps([map]);

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

      // Lines
      final lineFeatures = collections.lines['features'] as List;
      expect(lineFeatures.length, 1);
      final line = lineFeatures.first as Map<String, dynamic>;
      expect(line['geometry']['type'], 'LineString');
      final lineCoords = line['geometry']['coordinates'] as List;
      expect(lineCoords.first, [118.89, -2.67]);
      expect(lineCoords.last, [118.90, -2.68]);
      expect(line['properties']['width'], 4);

      // Points
      final pointFeatures = collections.points['features'] as List;
      expect(pointFeatures.length, 1);
      final pt = pointFeatures.first as Map<String, dynamic>;
      expect(pt['geometry']['type'], 'Point');
      expect(pt['geometry']['coordinates'], [118.89, -2.67]);
      expect(pt['properties']['name'], 'Pusat Titik');
    });
  });
}
