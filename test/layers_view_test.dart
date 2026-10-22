import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mmaps_flutter/models/imported_map.dart';
import 'package:mmaps_flutter/views/layers_view.dart';

void main() {
  testWidgets('a library map can be added to and removed from active layers', (
    WidgetTester tester,
  ) async {
    final map = ImportedMap(
      id: 'sample',
      name: 'Survey map',
      fileName: 'survey.kml',
      points: const [
        MapPointFeature(
          name: 'Point',
          point: LatLng(-2, 118),
          color: Colors.red,
        ),
      ],
      lines: const [],
      polygons: const [],
      overlays: const [],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => LayersView(
            selectedTab: 0,
            onTabChanged: (_) {},
            maps: [map],
            onImportMap: () {},
            onToggleMap: (item) => setState(() {
              item.isActive = !item.isActive;
            }),
            onRemoveMap: (_) {},
            importing: false,
            loading: false,
          ),
        ),
      ),
    );

    expect(find.text('Survey map'), findsOneWidget);
    expect(find.text('Belum ada layer aktif'), findsOneWidget);

    await tester.tap(find.text('Tambah'));
    await tester.pumpAndSettle();
    expect(
      find.byTooltip('Keluarkan Survey map dari Active Layers'),
      findsOneWidget,
    );
    expect(find.text('Belum ada layer aktif'), findsNothing);

    await tester.tap(find.byTooltip('Keluarkan Survey map dari Active Layers'));
    await tester.pumpAndSettle();
    expect(find.text('Belum ada layer aktif'), findsOneWidget);
  });
}
