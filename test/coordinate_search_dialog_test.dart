import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mmaps_flutter/widgets/coordinate_search_dialog.dart';

void main() {
  testWidgets('validates coordinates and returns a valid LatLng', (
    tester,
  ) async {
    LatLng? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await CoordinateSearchDialog.show(context);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Cari Koordinat'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), '91');
    await tester.enterText(find.byType(TextField).at(1), '-122.4');
    await tester.tap(find.text('Cari'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Masukkan latitude'), findsOneWidget);
    expect(result, isNull);

    await tester.enterText(find.byType(TextField).at(0), '-45.5');
    await tester.tap(find.text('Cari'));
    await tester.pumpAndSettle();

    expect(result, const LatLng(-45.5, -122.4));
    expect(find.text('Cari Koordinat'), findsNothing);
  });

  testWidgets('cancel closes the dialog without returning coordinates', (
    tester,
  ) async {
    LatLng? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await CoordinateSearchDialog.show(context);
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Batal'));
    await tester.pumpAndSettle();

    expect(result, isNull);
    expect(find.text('Cari Koordinat'), findsNothing);
  });
}
