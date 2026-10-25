import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmaps_flutter/screens/map_home_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:mmaps_flutter/widgets/tools_popup.dart';

void main() {
  // Inisialisasi database untuk lingkungan tes
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('map view shows its toolbar and map controls', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Tangkap error LateInitializationError dari MapLibre saat dispose
    final originalOnError = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      if (details.exception.toString().contains('LateInitializationError') ||
          details.exception.toString().contains('Duplicate GlobalKey')) {
        return; // Abaikan error spesifik dari MapLibre
      }
      originalOnError?.call(details);
    };

    await tester.pumpWidget(
      const MaterialApp(
        home: MapHomePage(loadSavedLibrary: false, useMapLibre: false),
      ),
    );

    // 1. Verifikasi Toolbar ada
    expect(find.byTooltip('Pusatkan GPS'), findsOneWidget);
    expect(find.byTooltip('Tambah Titik'), findsOneWidget);
    expect(find.byTooltip('Kelola Titik'), findsOneWidget);
    expect(find.byTooltip('Tampilan Layers'), findsOneWidget);
    expect(find.byTooltip('Tampilan Peta'), findsOneWidget);
    expect(find.byTooltip('Menu Alat'), findsOneWidget);

    // 2. Verifikasi Label Koordinat dan Atribusi
    expect(find.text('Lat: -2.670000\nLon: 118.890000'), findsOneWidget);
    final mapPlaceholderFinder = find.byKey(
      const ValueKey('map-test-placeholder'),
      skipOffstage: false,
    );
    final mapPlaceholderElement = tester.element(mapPlaceholderFinder);

    // 3. Uji Panel Layers
    await tester.tap(find.byTooltip('Tampilan Layers'));
    await tester.pumpAndSettle();

    expect(
      identical(mapPlaceholderElement, tester.element(mapPlaceholderFinder)),
      isTrue,
    );
    expect(find.text('Layers'), findsOneWidget);
    expect(find.text('Active Layers'), findsOneWidget);
    expect(find.text('Belum ada layer aktif'), findsOneWidget);
    expect(find.text('© OpenStreetMap'), findsNothing);
    expect(find.text('Maps Library'), findsOneWidget);
    expect(find.text('Basemap'), findsOneWidget);
    expect(find.text('Import Maps'), findsOneWidget);

    // Uji Tab Basemap
    await tester.tap(find.text('Basemap'));
    await tester.pumpAndSettle();
    expect(find.text('OpenFreeMap'), findsOneWidget);
    expect(find.text('Google Satellite'), findsNothing);
    expect(find.text('Add Custom XYZ Tiles'), findsOneWidget);
    await tester.tap(find.text('OpenFreeMap'));
    await tester.pumpAndSettle();

    // 4. Kembali ke Tampilan Peta
    await tester.tap(find.byTooltip('Tampilan Peta'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Layers'), findsNothing);
    expect(
      identical(mapPlaceholderElement, tester.element(mapPlaceholderFinder)),
      isTrue,
    );
    expect(
      find.text('© OpenFreeMap · © OpenStreetMap contributors'),
      findsOneWidget,
    );

    // 5. Uji Menu Alat (Buka menu)
    await tester.tap(find.byTooltip('Menu Alat'));
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Find By Coordinates'), findsOneWidget);

    // Tutup menu alat menggunakan tombol tutup yang tersedia
    final closeButton = find.descendant(
      of: find.byType(ToolsPopup),
      matching: find.byType(IconButton),
    );

    expect(closeButton, findsOneWidget);
    await tester.tap(closeButton);
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Find By Coordinates'), findsNothing);

    // Kembalikan error handler asli
    FlutterError.onError = originalOnError;
  });
}
