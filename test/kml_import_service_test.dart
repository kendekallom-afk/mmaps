import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmaps_flutter/services/kml_import_service.dart';

void main() {
  final service = KmlImportService();

  test('parses KML points, lines, and polygons', () {
    final map = service.parse(
      id: 'sample',
      fileName: 'sample.kml',
      bytes: Uint8List.fromList(
        utf8.encode('''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>Sample area</name>
    <Placemark>
      <name>Start</name>
      <Point><coordinates>118.5,-2.5</coordinates></Point>
    </Placemark>
    <Placemark>
      <name>Route</name>
      <LineString><coordinates>118.0,-2.0 118.1,-2.1</coordinates></LineString>
    </Placemark>
    <Placemark>
      <name>Area</name>
      <Polygon>
        <outerBoundaryIs><LinearRing><coordinates>
          118,-2 119,-2 119,-3 118,-3 118,-2
        </coordinates></LinearRing></outerBoundaryIs>
        <innerBoundaryIs><LinearRing><coordinates>
          118.2,-2.2 118.3,-2.2 118.3,-2.3 118.2,-2.3 118.2,-2.2
        </coordinates></LinearRing></innerBoundaryIs>
      </Polygon>
    </Placemark>
  </Document>
</kml>
'''),
      ),
    );

    expect(map.name, 'Sample area');
    expect(map.points, hasLength(1));
    expect(map.points.single.point.latitude, -2.5);
    expect(map.points.single.point.longitude, 118.5);
    expect(map.lines, hasLength(1));
    expect(map.lines.single.points, hasLength(2));
    expect(map.polygons, hasLength(1));
    expect(map.polygons.single.holes, hasLength(1));
    expect(map.bounds, isNotNull);
  });

  test('reports unpreserved spatial semantics as fatal with source paths', () {
    const cases = {
      'altitudeMode': '''
        <Point><altitudeMode>clampToGround</altitudeMode>
          <coordinates>1,2</coordinates></Point>
      ''',
      'extrude': '''
        <LineString><extrude>1</extrude>
          <coordinates>1,2 2,3</coordinates></LineString>
      ''',
      'tessellate': '''
        <Polygon><tessellate>1</tessellate><outerBoundaryIs>
          <LinearRing><coordinates>1,2 2,3 3,2</coordinates></LinearRing>
        </outerBoundaryIs></Polygon>
      ''',
      'LookAt': '<LookAt><longitude>1</longitude></LookAt>',
      'visibility': '<visibility>0</visibility>',
      'Region': '<Region><Lod><minLodPixels>1</minLodPixels></Lod></Region>',
      'TimeSpan': '<TimeSpan><begin>2020</begin></TimeSpan>',
      'TimeStamp': '<TimeStamp><when>2020</when></TimeStamp>',
      'NetworkLink': '<NetworkLink><name>Remote</name></NetworkLink>',
      'ExtendedData':
          '<ExtendedData><Data name="x"><value>y</value></Data></ExtendedData>',
      'unsupported MultiGeometry child':
          '<MultiGeometry><Model/></MultiGeometry>',
      'unknown element': '<UnexpectedKmlElement/>',
      'unknown geometry attribute':
          '<Point targetId="feature"><coordinates>1,2</coordinates></Point>',
      'unretained geometry id':
          '<Point id="feature"><coordinates>1,2</coordinates></Point>',
    };

    for (final entry in cases.entries) {
      final xml =
          '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document><name>Document name</name><Folder><name>Folder name</name>
    <Placemark><name>Site name</name>${entry.value}
      <Point><coordinates>1,2</coordinates></Point>
    </Placemark>
  </Folder></Document>
</kml>
''';
      final result = service.parseWithIssues(
        id: 'unsupported',
        fileName: 'unsupported.kml',
        bytes: Uint8List.fromList(utf8.encode(xml)),
      );

      final issue = result.issues.firstWhere(
        (item) =>
            item.severity == ImportIssueSeverity.error &&
            item.code == ImportIssueCode.unsupportedContent &&
            item.sourceReference?.contains('Placemark(name="Site name")') ==
                true,
        orElse: () => throw StateError('No fatal issue for ${entry.key}'),
      );
      expect(
        issue.sourceReference,
        contains('Folder(name="Folder name")'),
        reason: entry.key,
      );
      expect(
        issue.sourceReference,
        contains('Placemark(name="Site name")'),
        reason: entry.key,
      );
    }
  });

  test('keeps unsupported style content as a warning', () {
    const xml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Placemark><Style id="s"><IconStyle><scale>2</scale></IconStyle></Style>
    <Point><coordinates>1,2</coordinates></Point>
  </Placemark>
</kml>
''';
    final result = service.parseWithIssues(
      id: 'style-warning',
      fileName: 'style-warning.kml',
      bytes: Uint8List.fromList(utf8.encode(xml)),
    );

    expect(result.issues, hasLength(1));
    expect(result.issues.single.severity, ImportIssueSeverity.warning);
    expect(result.issues.single.sourceReference, contains('s'));
  });

  test('preserves the KML polygon outline color for optional display', () {
    final map = service.parse(
      id: 'no-outline',
      fileName: 'no-outline.kml',
      bytes: Uint8List.fromList(
        utf8.encode('''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Placemark>
    <Style><PolyStyle><color>ff00ff00</color><outline>1</outline></PolyStyle></Style>
    <Polygon>
      <outerBoundaryIs><LinearRing><coordinates>
        118,-2 119,-2 119,-3 118,-3 118,-2
      </coordinates></LinearRing></outerBoundaryIs>
    </Polygon>
  </Placemark>
</kml>
'''),
      ),
    );

    expect(map.polygons.single.fillColor, const Color(0xFF00FF00));
    expect(map.polygons.single.borderColor, Colors.blue);
  });

  test('preserves the KMZ polygon outline color for optional display', () {
    const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Placemark>
    <Style><PolyStyle><color>ff00ff00</color><outline>1</outline></PolyStyle></Style>
    <Polygon>
      <outerBoundaryIs><LinearRing><coordinates>
        118,-2 119,-2 119,-3 118,-3 118,-2
      </coordinates></LinearRing></outerBoundaryIs>
    </Polygon>
  </Placemark>
</kml>
''';
    final archive = Archive()..add(ArchiveFile.string('doc.kml', kml));
    final map = service.parse(
      id: 'no-outline-kmz',
      fileName: 'no-outline.kmz',
      bytes: Uint8List.fromList(ZipEncoder().encode(archive)),
    );

    expect(map.polygons.single.fillColor, const Color(0xFF00FF00));
    expect(map.polygons.single.borderColor, Colors.blue);
  });

  test('KML parse result can be transferred from compute isolate', () async {
    final map = await compute(parseKmlInBackground, (
      id: 'isolate',
      fileName: 'isolate.kml',
      bytes: Uint8List.fromList(
        utf8.encode('''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document><name>Isolate map</name><Placemark>
    <Point><coordinates>118.5,-2.5</coordinates></Point>
  </Placemark></Document>
</kml>
'''),
      ),
    ));

    expect(map.name, 'Isolate map');
    expect(map.points.single.point.latitude, -2.5);
    expect(map.points.single.color, isNotNull);
  });

  test('reads an embedded GroundOverlay image from KMZ', () {
    const kml = '''
<kml xmlns="http://www.opengis.net/kml/2.2">
  <Document>
    <name>Raster map</name>
    <GroundOverlay>
      <name>Sheet 1</name>
      <Icon><href>images/sheet.png</href></Icon>
      <LatLonBox>
        <north>-2</north><south>-3</south><east>119</east><west>118</west>
      </LatLonBox>
    </GroundOverlay>
  </Document>
</kml>
''';
    final pngBytes = Uint8List.fromList([
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
    ]);
    final archive = Archive()
      ..add(ArchiveFile.string('folder/doc.kml', kml))
      ..add(ArchiveFile.bytes('folder/images/sheet.png', pngBytes));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

    final map = service.parse(
      id: 'raster',
      fileName: 'raster.kmz',
      bytes: bytes,
    );

    expect(map.name, 'Raster map');
    expect(map.overlays, hasLength(1));
    expect(map.overlays.single.name, 'Sheet 1');
    expect(map.overlays.single.bytes, pngBytes);
  });

  test('rejects KML that has no renderable map features', () {
    expect(
      () => service.parse(
        id: 'empty',
        fileName: 'empty.kml',
        bytes: Uint8List.fromList(
          utf8.encode('<kml><Document><name>Empty</name></Document></kml>'),
        ),
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('legacy parse API preserves altitude and accepts 2D coordinates', () {
    final map = service.parse(
      id: 'altitude',
      fileName: 'altitude.kml',
      bytes: Uint8List.fromList(
        utf8.encode('''
<kml>
  <Placemark><name>2D</name><Point><coordinates>118.5,-2.5</coordinates></Point></Placemark>
  <Placemark><name>3D</name><Point><coordinates>119.5,-3.5,125.6</coordinates></Point></Placemark>
  <Placemark><name>Mixed line</name><LineString><coordinates>120,-4,0 121,-5,-12.5 122,-6</coordinates></LineString></Placemark>
  <Placemark><name>3D polygon</name><Polygon>
    <outerBoundaryIs><LinearRing><coordinates>
      123,-7,4 124,-7,5 124,-8,6 123,-8,7 123,-7,4
    </coordinates></LinearRing></outerBoundaryIs>
    <innerBoundaryIs><LinearRing><coordinates>
      123.2,-7.2,0 123.8,-7.2,-1 123.8,-7.8,-2 123.2,-7.8,-3 123.2,-7.2,0
    </coordinates></LinearRing></innerBoundaryIs>
  </Polygon></Placemark>
</kml>
'''),
      ),
    );

    expect(map.points, hasLength(2));
    expect(map.points[0].point.longitude, 118.5);
    expect(map.points[0].point.latitude, -2.5);
    expect(map.points[0].altitude, isNull);
    expect(map.points[1].point.longitude, 119.5);
    expect(map.points[1].point.latitude, -3.5);
    expect(map.points[1].altitude, 125.6);
    expect(map.lines.single.altitudes, [0.0, -12.5, null]);
    expect(map.polygons.single.altitudes, [4.0, 5.0, 6.0, 7.0, 4.0]);
    expect(map.polygons.single.holeAltitudes.single, [
      0.0,
      -1.0,
      -2.0,
      -3.0,
      0.0,
    ]);
  });
}
