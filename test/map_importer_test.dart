import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmaps_flutter/models/map_meta.dart';
import 'package:mmaps_flutter/models/map_overlay_manifest.dart';
import 'package:mmaps_flutter/services/map_importer.dart';

const _pngBytes = <int>[
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  13,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  96,
  96,
  96,
  248,
  15,
  0,
  1,
  4,
  1,
  0,
  95,
  229,
  195,
  75,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
];

const _geometryKml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document><name>Parsed map</name>
    <Placemark><name>Point</name>
      <Point><coordinates>179.25,-2.125</coordinates></Point>
    </Placemark>
    <Placemark><name>Line</name>
      <LineString><coordinates>179.5,-2.25 -179.5,-2.5</coordinates></LineString>
    </Placemark>
    <Placemark><name>Polygon</name>
      <Polygon>
        <outerBoundaryIs><LinearRing><coordinates>
          179,-2 179.5,-2 -179.5,-2 -179,-2 179,-2
        </coordinates></LinearRing></outerBoundaryIs>
        <innerBoundaryIs><LinearRing><coordinates>
          179.1,-2.1 179.2,-2.1 179.2,-2.2 179.1,-2.2 179.1,-2.1
        </coordinates></LinearRing></innerBoundaryIs>
      </Polygon>
    </Placemark>
  </Document>
</kml>
''';

Uint8List _kmz(String kml, {bool includeOverlayAsset = true}) {
  final archive = Archive()..add(ArchiveFile.string('maps/doc.kml', kml));
  if (includeOverlayAsset) {
    archive.add(ArchiveFile.bytes('maps/images/overlay.png', _pngBytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Uint8List _kmzWithImages(String kml, Map<String, List<int>> images) {
  final archive = Archive()..add(ArchiveFile.string('maps/doc.kml', kml));
  for (final entry in images.entries) {
    archive.add(ArchiveFile.bytes('maps/${entry.key}', entry.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  group('MapImporter in-memory package', () {
    final importer = MapImporter(
      clock: () => DateTime.utc(2026, 11, 4, 7, 0, 0),
    );

    test(
      'creates all three GeoJSON collections and metadata from geometry',
      () async {
        final input = Uint8List.fromList(utf8.encode(_geometryKml));
        final package = await importer.importMap(
          sourceBytes: input,
          sourceFileName: 'source.kml',
          mapId: 'map_001',
        );

        expect(package.metadata.id, 'map_001');
        expect(package.metadata.name, 'Parsed map');
        expect(package.metadata.originalExtension, 'kml');
        expect(package.metadata.polygonCount, 1);
        expect(package.metadata.lineCount, 1);
        expect(package.metadata.pointCount, 1);
        expect(package.metadata.bounds, [-179.5, -2.5, 179.5, -2.0]);

        final polygons = jsonDecode(package.geoJson.polygons) as Map;
        final lines = jsonDecode(package.geoJson.lines) as Map;
        final points = jsonDecode(package.geoJson.points) as Map;
        expect(polygons['type'], 'FeatureCollection');
        expect(lines['type'], 'FeatureCollection');
        expect(points['type'], 'FeatureCollection');

        final polygon = (polygons['features'] as List).single as Map;
        final rings = polygon['geometry']['coordinates'] as List;
        expect(rings, hasLength(2));
        expect(rings.first, [
          [179.0, -2.0],
          [179.5, -2.0],
          [-179.5, -2.0],
          [-179.0, -2.0],
          [179.0, -2.0],
        ]);
        expect(rings[1].first, [179.1, -2.1]);
        expect(rings[1].last, [179.1, -2.1]);

        final line = (lines['features'] as List).single as Map;
        expect(line['geometry']['coordinates'], [
          [179.5, -2.25],
          [-179.5, -2.5],
        ]);
        expect((points['features'] as List).single['geometry']['coordinates'], [
          179.25,
          -2.125,
        ]);
        expect(
          jsonDecode(package.layerStyleJson)['source'],
          'mMaps-application-defaults',
        );
        expect(package.overlayManifest.overlays, isEmpty);
        expect(package.overlayAssets, isEmpty);
      },
    );

    test('imports a KMZ containing only one valid GroundOverlay', () async {
      const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document><name>Raster only</name>
    <GroundOverlay><name>Single sheet</name>
      <Icon><href>images/overlay.png</href></Icon>
      <LatLonBox><north>10</north><south>5</south><east>20</east><west>15</west></LatLonBox>
    </GroundOverlay>
  </Document>
</kml>
''';
      final package = await importer.importMap(
        sourceBytes: _kmz(kml),
        sourceFileName: 'raster_only.kmz',
        mapId: 'raster_only',
      );

      expect(package.metadata.bounds, [15.0, 5.0, 20.0, 10.0]);
      expect(package.metadata.polygonCount, 0);
      expect(package.metadata.lineCount, 0);
      expect(package.metadata.pointCount, 0);
      expect(
        (jsonDecode(package.geoJson.polygons)['features'] as List),
        isEmpty,
      );
      expect((jsonDecode(package.geoJson.lines)['features'] as List), isEmpty);
      expect((jsonDecode(package.geoJson.points)['features'] as List), isEmpty);
      expect(package.overlayManifest.overlays.single.name, 'Single sheet');
      expect(package.overlayAssets.single.bytes, orderedEquals(_pngBytes));
    });

    test('uses the union of multiple raster-only overlay bounds', () async {
      const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document><name>Raster set</name>
    <GroundOverlay><name>First</name>
      <Icon><href>images/first.png</href></Icon>
      <LatLonBox><north>10</north><south>5</south><east>20</east><west>15</west></LatLonBox>
    </GroundOverlay>
    <GroundOverlay><name>Second</name>
      <Icon><href>images/second.png</href></Icon>
      <LatLonBox><north>12</north><south>3</south><east>25</east><west>10</west></LatLonBox>
    </GroundOverlay>
  </Document>
</kml>
''';
      final package = await importer.importMap(
        sourceBytes: _kmzWithImages(kml, {
          'images/first.png': _pngBytes,
          'images/second.png': _pngBytes,
        }),
        sourceFileName: 'raster_set.kmz',
        mapId: 'raster_set',
      );

      expect(package.metadata.bounds, [10.0, 3.0, 25.0, 12.0]);
      expect(package.metadata.polygonCount, 0);
      expect(package.metadata.lineCount, 0);
      expect(package.metadata.pointCount, 0);
      expect(package.overlayManifest.overlays, hasLength(2));
      expect(package.overlayAssets, hasLength(2));
    });

    test(
      'keeps combination package bounds based on vector geometry only',
      () async {
        const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document><name>Combined</name>
    <Placemark><Point><coordinates>1,2,9000000</coordinates></Point></Placemark>
    <GroundOverlay><name>Remote sheet</name>
      <Icon><href>images/overlay.png</href></Icon>
      <LatLonBox><north>80</north><south>70</south><east>120</east><west>110</west></LatLonBox>
    </GroundOverlay>
  </Document>
</kml>
''';
        final package = await importer.importMap(
          sourceBytes: _kmz(kml),
          sourceFileName: 'combined.kmz',
          mapId: 'combined',
        );

        expect(package.metadata.bounds, [1.0, 2.0, 1.0, 2.0]);
        expect(package.metadata.pointCount, 1);
        expect(package.overlayManifest.overlays, hasLength(1));
      },
    );

    test('rejects a package with no vector features or valid overlays', () {
      expect(
        () => ImportPackage(
          metadata: MapMeta(
            id: 'empty_package',
            formatVersion: MapMeta.currentFormatVersion,
            name: 'Empty',
            originalExtension: 'kml',
            importedAt: DateTime.utc(2026),
            polygonCount: 0,
            lineCount: 0,
            pointCount: 0,
            bounds: [0, 0, 0, 0],
          ),
          originalSource: OriginalMapSource(
            extension: 'kml',
            bytes: Uint8List.fromList(utf8.encode('<kml/>')),
          ),
          geoJson: const MapGeometryGeoJson(
            polygons: '{"type":"FeatureCollection","features":[]}',
            lines: '{"type":"FeatureCollection","features":[]}',
            points: '{"type":"FeatureCollection","features":[]}',
          ),
          layerStyleJson: '{}',
          overlayManifest: MapOverlayManifest(overlays: const []),
          overlayAssets: const [],
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('preserves parser style warnings in a valid import package', () async {
      const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document><name>Styled point</name>
    <Style id="custom"><IconStyle><scale>2</scale></IconStyle></Style>
    <Placemark><styleUrl>#custom</styleUrl><Point><coordinates>1,2</coordinates></Point></Placemark>
  </Document>
</kml>
''';
      final package = await importer.importMap(
        sourceBytes: Uint8List.fromList(utf8.encode(kml)),
        sourceFileName: 'style_warning.kml',
        mapId: 'style_warning',
      );

      expect(package.warnings, isNotEmpty);
      expect(
        package.warnings.every(
          (issue) => issue.severity == ImportIssueSeverity.warning,
        ),
        isTrue,
      );
      expect(
        package.warnings.map((issue) => issue.code),
        contains(ImportIssueCode.unsupportedContent),
      );
    });

    test(
      'rejects unpreserved geometry semantics during package import',
      () async {
        const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document><Folder><name>Survey</name>
    <Placemark><name>Marker</name>
      <Point><altitudeMode>relativeToGround</altitudeMode><coordinates>1,2</coordinates></Point>
    </Placemark>
  </Folder></Document>
</kml>
''';

        await expectLater(
          importer.importMap(
            sourceBytes: Uint8List.fromList(utf8.encode(kml)),
            sourceFileName: 'unpreserved_semantics.kml',
            mapId: 'unpreserved_semantics',
          ),
          throwsA(
            isA<MapImportContentException>().having(
              (error) => error.issues.any(
                (issue) =>
                    issue.severity == ImportIssueSeverity.error &&
                    issue.code == ImportIssueCode.unsupportedContent &&
                    issue.sourceReference!.contains('altitudeMode') &&
                    issue.sourceReference!.contains('name="Survey"') &&
                    issue.sourceReference!.contains('name="Marker"'),
              ),
              'includes a fatal issue with its element path',
              isTrue,
            ),
          ),
        );
      },
    );

    test('keeps invalid spatial coordinates fatal', () async {
      const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Placemark><Point><coordinates>181,2</coordinates></Point></Placemark>
</kml>
''';
      await expectLater(
        importer.importMap(
          sourceBytes: Uint8List.fromList(utf8.encode(kml)),
          sourceFileName: 'invalid_spatial.kml',
          mapId: 'invalid_spatial',
        ),
        throwsA(
          isA<MapImportContentException>().having(
            (error) => error.issues.any(
              (issue) =>
                  issue.code == ImportIssueCode.invalidGeometryCoordinate &&
                  issue.severity == ImportIssueSeverity.error,
            ),
            'contains fatal spatial coordinate issue',
            isTrue,
          ),
        ),
      );
    });

    test(
      'preserves 2D and 3D coordinates, dimensions, and geometry order',
      () async {
        const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <Placemark><name>Point 2D</name><Point><coordinates>100,10</coordinates></Point></Placemark>
    <Placemark><name>Point 3D</name><Point><coordinates>101,11,0</coordinates></Point></Placemark>
    <Placemark><name>Line mixed</name><LineString><coordinates>10,20,0 11,21,-5000000 12,22</coordinates></LineString></Placemark>
    <Placemark><name>Line second</name><LineString><coordinates>13,23,9 14,24,5000000</coordinates></LineString></Placemark>
    <Placemark><name>Polygon 3D</name><Polygon>
      <outerBoundaryIs><LinearRing><coordinates>
        1,1,1 4,1,2 4,4,3 1,4,4 1,1,1
      </coordinates></LinearRing></outerBoundaryIs>
      <innerBoundaryIs><LinearRing><coordinates>
        2,2,0 3,2,-1 3,3,-2 2,3,-3 2,2,0
      </coordinates></LinearRing></innerBoundaryIs>
      <innerBoundaryIs><LinearRing><coordinates>
        2.2,2.2,8 2.8,2.2,7 2.8,2.8,6 2.2,2.8,5 2.2,2.2,8
      </coordinates></LinearRing></innerBoundaryIs>
    </Polygon></Placemark>
    <Placemark><name>Polygon 2D</name><Polygon>
      <outerBoundaryIs><LinearRing><coordinates>
        5,5 6,5 6,6 5,6 5,5
      </coordinates></LinearRing></outerBoundaryIs>
    </Polygon></Placemark>
  </Document>
</kml>
''';
        final package = await importer.importMap(
          sourceBytes: Uint8List.fromList(utf8.encode(kml)),
          sourceFileName: 'dimensions.kml',
          mapId: 'dimensions',
        );

        expect(package.metadata.bounds, [1.0, 1.0, 101.0, 24.0]);

        final pointFeatures =
            (jsonDecode(package.geoJson.points)['features'] as List)
                .cast<Map<String, dynamic>>();
        expect(pointFeatures.map((feature) => feature['properties']['name']), [
          'Point 2D',
          'Point 3D',
        ]);
        expect(pointFeatures[0]['geometry']['coordinates'], [100.0, 10.0]);
        expect(pointFeatures[1]['geometry']['coordinates'], [101.0, 11.0, 0.0]);

        final lineFeatures =
            (jsonDecode(package.geoJson.lines)['features'] as List)
                .cast<Map<String, dynamic>>();
        expect(lineFeatures.map((feature) => feature['properties']['name']), [
          'Line mixed',
          'Line second',
        ]);
        expect(lineFeatures[0]['geometry']['coordinates'], [
          [10.0, 20.0, 0.0],
          [11.0, 21.0, -5000000.0],
          [12.0, 22.0],
        ]);
        expect(lineFeatures[1]['geometry']['coordinates'], [
          [13.0, 23.0, 9.0],
          [14.0, 24.0, 5000000.0],
        ]);

        final polygonFeatures =
            (jsonDecode(package.geoJson.polygons)['features'] as List)
                .cast<Map<String, dynamic>>();
        expect(
          polygonFeatures.map((feature) => feature['properties']['name']),
          ['Polygon 3D', 'Polygon 2D'],
        );
        final rings = polygonFeatures[0]['geometry']['coordinates'] as List;
        expect(rings, hasLength(3));
        expect(rings[0], [
          [1.0, 1.0, 1.0],
          [4.0, 1.0, 2.0],
          [4.0, 4.0, 3.0],
          [1.0, 4.0, 4.0],
          [1.0, 1.0, 1.0],
        ]);
        expect(rings[1], [
          [2.0, 2.0, 0.0],
          [3.0, 2.0, -1.0],
          [3.0, 3.0, -2.0],
          [2.0, 3.0, -3.0],
          [2.0, 2.0, 0.0],
        ]);
        expect(rings[2].first, [2.2, 2.2, 8.0]);
        expect(rings[2].last, [2.2, 2.2, 8.0]);
        expect(polygonFeatures[1]['geometry']['coordinates'][0].first, [
          5.0,
          5.0,
        ]);
      },
    );

    test('copies original source bytes defensively', () async {
      final input = Uint8List.fromList(utf8.encode(_geometryKml));
      final expected = Uint8List.fromList(input);
      final package = await importer.importMap(
        sourceBytes: input,
        sourceFileName: 'source.kml',
        mapId: 'copy_source',
      );

      input[0] = 0;
      final exposedBytes = package.originalSource.bytes;
      exposedBytes[1] = 0;

      expect(package.originalSource.bytes, orderedEquals(expected));
    });

    test('preserves overlay bytes and source bounds in manifest', () async {
      const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document><name>Overlay map</name>
    <Placemark><Point><coordinates>12.5,-4.25</coordinates></Point></Placemark>
    <GroundOverlay><name>Sheet</name>
      <Icon><href>images/overlay.png</href></Icon>
      <LatLonBox>
        <north>-2.123456789</north><south>-3.25</south>
        <east>-179.75</east><west>179.5</west>
      </LatLonBox>
    </GroundOverlay>
  </Document>
</kml>
''';
      final package = await importer.importMap(
        sourceBytes: _kmz(kml),
        sourceFileName: 'source.kmz',
        mapId: 'overlay_map',
      );

      final manifestEntry = package.overlayManifest.overlays.single;
      expect(manifestEntry.file, 'overlay_0001.png');
      expect(manifestEntry.imageFormat, 'png');
      expect(manifestEntry.bounds.north, -2.123456789);
      expect(manifestEntry.bounds.west, 179.5);

      final asset = package.overlayAssets.single;
      expect(asset.bytes, orderedEquals(_pngBytes));
      final exposedBytes = asset.bytes;
      exposedBytes[0] = 0;
      expect(package.overlayAssets.single.bytes, orderedEquals(_pngBytes));
    });

    test('rejects invalid IDs without normalizing them', () async {
      await expectLater(
        importer.importMap(
          sourceBytes: Uint8List.fromList(utf8.encode(_geometryKml)),
          sourceFileName: 'source.kml',
          mapId: 'Uppercase',
        ),
        throwsA(isA<MapImportInputException>()),
      );
    });

    test('uses overlay bounds when there are no vector coordinates', () async {
      const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <GroundOverlay><name>Only raster</name>
    <Icon><href>images/overlay.png</href></Icon>
    <LatLonBox><north>1</north><south>0</south><east>1</east><west>0</west></LatLonBox>
  </GroundOverlay>
</kml>
''';
      final package = await importer.importMap(
        sourceBytes: _kmz(kml),
        sourceFileName: 'overlay_only.kmz',
        mapId: 'overlay_only',
      );

      expect(package.metadata.bounds, [0.0, 0.0, 1.0, 1.0]);
      expect(package.metadata.pointCount, 0);
      expect(package.metadata.lineCount, 0);
      expect(package.metadata.polygonCount, 0);
    });

    test(
      'keeps absent geometry types as valid empty FeatureCollections',
      () async {
        const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Placemark><Point><coordinates>12.5,-4.25</coordinates></Point></Placemark>
</kml>
''';
        final package = await importer.importMap(
          sourceBytes: Uint8List.fromList(utf8.encode(kml)),
          sourceFileName: 'single_point.kml',
          mapId: 'single_point',
          displayName: 'Explicit name',
        );

        expect(package.metadata.name, 'Explicit name');
        expect(
          (jsonDecode(package.geoJson.polygons)['features'] as List),
          isEmpty,
        );
        expect(
          (jsonDecode(package.geoJson.lines)['features'] as List),
          isEmpty,
        );
        expect(
          (jsonDecode(package.geoJson.points)['features'] as List),
          hasLength(1),
        );
      },
    );

    test('does not silently close a polygon ring for GeoJSON', () async {
      const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Placemark><Polygon><outerBoundaryIs><LinearRing><coordinates>
    1,1 2,1 2,2 1,2
  </coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>
</kml>
''';
      await expectLater(
        importer.importMap(
          sourceBytes: Uint8List.fromList(utf8.encode(kml)),
          sourceFileName: 'open_ring.kml',
          mapId: 'open_ring',
        ),
        throwsA(isA<MapImportPackageException>()),
      );
    });

    test(
      'fails safely and exposes issue for a remote overlay reference',
      () async {
        const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Placemark><Point><coordinates>1,2</coordinates></Point></Placemark>
  <GroundOverlay><name>Remote</name>
    <Icon><href>https://example.invalid/map.png</href></Icon>
    <LatLonBox><north>3</north><south>2</south><east>2</east><west>1</west></LatLonBox>
  </GroundOverlay>
</kml>
''';
        try {
          await importer.importMap(
            sourceBytes: _kmz(kml, includeOverlayAsset: false),
            sourceFileName: 'remote.kmz',
            mapId: 'remote_map',
          );
          fail('Expected import to fail');
        } on MapImportContentException catch (error) {
          expect(
            error.issues.map((issue) => issue.code),
            contains(ImportIssueCode.remoteOverlayReference),
          );
        }
      },
    );

    test(
      'fails safely and exposes issue for a missing overlay image',
      () async {
        const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Placemark><Point><coordinates>1,2</coordinates></Point></Placemark>
  <GroundOverlay><name>Missing</name>
    <Icon><href>images/not_in_archive.png</href></Icon>
    <LatLonBox><north>3</north><south>2</south><east>2</east><west>1</west></LatLonBox>
  </GroundOverlay>
</kml>
''';
        try {
          await importer.importMap(
            sourceBytes: _kmz(kml, includeOverlayAsset: false),
            sourceFileName: 'missing.kmz',
            mapId: 'missing_map',
          );
          fail('Expected import to fail');
        } on MapImportContentException catch (error) {
          expect(
            error.issues.map((issue) => issue.code),
            contains(ImportIssueCode.missingOverlayAsset),
          );
        }
      },
    );

    test('emits failed progress with the structured import error', () async {
      final progress = <ImportProgress>[];
      const kml = '''
<kml><Placemark><Point><coordinates>1,2,invalid</coordinates></Point></Placemark></kml>
''';
      await expectLater(
        importer.importMap(
          sourceBytes: Uint8List.fromList(utf8.encode(kml)),
          sourceFileName: 'altitude.kml',
          mapId: 'altitude_map',
          onProgress: progress.add,
        ),
        throwsA(isA<MapImportContentException>()),
      );
      expect(progress.last.status, ImportProgressStatus.failed);
      expect(progress.last.error, isA<MapImportContentException>());
      expect(progress.last.stage, ImportProgressStage.parsing);
    });

    test(
      'fails safely for invalid overlay bounds and unsupported behavior',
      () async {
        const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Placemark><Point><coordinates>1,2</coordinates></Point></Placemark>
  <GroundOverlay><name>Rotated</name>
    <Icon><href>images/overlay.png</href></Icon>
    <LatLonBox><north>1</north><south>2</south><east>2</east><west>1</west><rotation>15</rotation></LatLonBox>
  </GroundOverlay>
</kml>
''';
        try {
          await importer.importMap(
            sourceBytes: _kmz(kml),
            sourceFileName: 'invalid_bounds.kmz',
            mapId: 'invalid_bounds',
          );
          fail('Expected import to fail');
        } on MapImportContentException catch (error) {
          final codes = error.issues.map((issue) => issue.code);
          expect(codes, contains(ImportIssueCode.invalidOverlayBounds));
          expect(codes, contains(ImportIssueCode.unsupportedOverlayBehavior));
        }
      },
    );

    test('fails safely when Placemark metadata cannot be retained', () async {
      const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Placemark><name>Has data</name><description>Details</description>
    <Point><coordinates>1,2</coordinates></Point>
  </Placemark>
</kml>
''';
      try {
        await importer.importMap(
          sourceBytes: Uint8List.fromList(utf8.encode(kml)),
          sourceFileName: 'description.kml',
          mapId: 'description_map',
        );
        fail('Expected import to fail');
      } on MapImportContentException catch (error) {
        expect(
          error.issues.map((issue) => issue.code),
          contains(ImportIssueCode.unsupportedContent),
        );
      }
    });
  });
}
