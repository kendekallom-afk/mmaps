import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maplibre_gl/maplibre_gl.dart' as ml;
import 'package:mmaps_flutter/screens/map_home_page.dart';

void main() {
  testWidgets('map view shows its toolbar and map controls', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      const MaterialApp(home: MapHomePage(loadSavedLibrary: false)),
    );

    expect(find.byTooltip('Pusatkan GPS'), findsOneWidget);
    expect(find.byTooltip('Tambah Titik'), findsOneWidget);
    expect(find.byTooltip('Kelola Titik'), findsOneWidget);
    expect(find.byTooltip('Tampilan Layers'), findsOneWidget);
    expect(find.byTooltip('Tampilan Peta'), findsOneWidget);
    expect(find.byTooltip('Menu Alat'), findsOneWidget);
    expect(find.text('© OpenStreetMap'), findsOneWidget);
    expect(find.text('Lat: -2.670000\nLon: 118.890000'), findsOneWidget);

    await tester.drag(find.byType(ml.MapLibreMap), const Offset(70, 0));
    await tester.pumpAndSettle();
    expect(find.text('Lat: -2.670000\nLon: 118.890000'), findsNothing);

    await tester.tap(find.byTooltip('Tampilan Layers'));
    await tester.pumpAndSettle();
    expect(find.text('Layers'), findsOneWidget);
    expect(find.text('Active Layers'), findsOneWidget);
    expect(find.text('Belum ada layer aktif'), findsOneWidget);
    expect(find.text('Maps Library'), findsOneWidget);
    expect(find.text('Basemap'), findsOneWidget);
    expect(find.text('Import Maps'), findsOneWidget);
    expect(find.text('© OpenStreetMap'), findsNothing);

    await tester.tap(find.text('Basemap'));
    await tester.pumpAndSettle();
    expect(find.text('Satelit'), findsOneWidget);
    expect(find.text('Terrain'), findsOneWidget);

    await tester.tap(find.byTooltip('Tampilan Peta'));
    await tester.pumpAndSettle();
    expect(find.text('Layers'), findsNothing);
    expect(find.text('© OpenStreetMap'), findsOneWidget);

    await tester.tap(find.byTooltip('Menu Alat'));
    await tester.pumpAndSettle();
    expect(find.text('Find By Coordinates'), findsOneWidget);

    await tester.tap(find.byTooltip('Tutup menu alat'));
    await tester.pumpAndSettle();
    expect(find.text('Find By Coordinates'), findsNothing);

    await tester.tap(find.byTooltip('Transparansi peta'));
    await tester.pumpAndSettle();
    expect(find.text('100%'), findsOneWidget);
  });
}
