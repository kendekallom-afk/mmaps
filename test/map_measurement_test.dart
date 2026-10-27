import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmaps_flutter/screens/map_home_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets(
    'measure mode supports adding, undoing, clearing, and finishing',
    (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        const MaterialApp(
          home: MapHomePage(loadSavedLibrary: false, useMapLibre: false),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Menu Alat'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Measure Distance or Area'));
      await tester.pumpAndSettle();

      expect(find.text('Jarak: 0 m'), findsOneWidget);
      expect(find.text('Titik: 0'), findsOneWidget);

      await tester.tap(find.text('Tambah'));
      await tester.pump();
      await tester.tap(find.text('Tambah'));
      await tester.pump();
      await tester.tap(find.text('Tambah'));
      await tester.pump();

      expect(find.text('Luas: 0 m²'), findsOneWidget);
      expect(find.text('Titik: 3'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pump();
      expect(find.text('Luas: 0 m²'), findsNothing);
      expect(find.text('Titik: 2'), findsOneWidget);

      await tester.tap(find.text('Clear'));
      await tester.pump();
      expect(find.text('Titik: 0'), findsOneWidget);

      await tester.tap(find.text('Selesai'));
      await tester.pumpAndSettle();
      expect(find.text('Jarak: 0 m'), findsNothing);
    },
  );
}
