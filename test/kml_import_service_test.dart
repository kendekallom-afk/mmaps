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
      <Point><coordinates>118.5,-2.5,0</coordinates></Point>
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
          118.2,-2.2 118.3,-2.2 118.3,-2.3 118.2,-2.2
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
    <Point><coordinates>118.5,-2.5,0</coordinates></Point>
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
    final archive = Archive()
      ..add(ArchiveFile.string('folder/doc.kml', kml))
      ..add(ArchiveFile.bytes('folder/images/sheet.png', [1, 2, 3, 4]));
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));

    final map = service.parse(
      id: 'raster',
      fileName: 'raster.kmz',
      bytes: bytes,
    );

    expect(map.name, 'Raster map');
    expect(map.overlays, hasLength(1));
    expect(map.overlays.single.name, 'Sheet 1');
    expect(map.overlays.single.bytes, [1, 2, 3, 4]);
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
}
