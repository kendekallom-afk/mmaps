import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mmaps_flutter/models/basemap.dart';
import 'package:mmaps_flutter/models/imported_map.dart';
import 'package:mmaps_flutter/views/layers_view.dart';
import 'package:mmaps_flutter/widgets/custom_xyz_tiles_sheet.dart';

void main() {
  testWidgets('a library map can be added to and removed from active layers', (
    WidgetTester tester,
  ) async {
    Basemap? activeBasemap;
    var selectedTab = 0;
    final customBasemaps = <Basemap>[];
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
            selectedTab: selectedTab,
            onTabChanged: (tab) => setState(() => selectedTab = tab),
            maps: [map],
            customBasemaps: customBasemaps,
            activeBasemap: activeBasemap,
            onBasemapChanged: (basemap) =>
                setState(() => activeBasemap = basemap),
            onAddCustomBasemap: () async {
              final basemap = await showCustomXyzTilesSheet(
                tester.element(find.byType(LayersView)),
              );
              if (basemap != null) {
                setState(() => customBasemaps.add(basemap));
              }
            },
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

    await tester.tap(find.text('Basemap'));
    await tester.pumpAndSettle();
    expect(find.text('OpenFreeMap'), findsOneWidget);
    expect(find.text('Google Satellite'), findsNothing);
    expect(find.text('Add Custom XYZ Tiles'), findsOneWidget);

    await tester.tap(find.text('OpenFreeMap'));
    await tester.pumpAndSettle();
    expect(find.byType(ActiveBasemapItem), findsOneWidget);
    expect(
      tester.getTopLeft(find.byType(ActiveMapItem)).dy,
      lessThan(tester.getTopLeft(find.byType(ActiveBasemapItem)).dy),
    );

    await tester.tap(find.text('Add Custom XYZ Tiles'));
    await tester.pumpAndSettle();
    expect(find.text('URL XYZ Tiles'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('custom-xyz-name')),
      'Topo',
    );
    await tester.enterText(
      find.byKey(const ValueKey('custom-xyz-url')),
      'https://tiles.example.com/{z}/{x}.png',
    );
    await tester.tap(find.byKey(const ValueKey('submit-custom-xyz-tiles')));
    await tester.pumpAndSettle();
    expect(find.text('URL harus memuat {z}, {x}, dan {y}.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey('custom-xyz-url')),
      'https://tiles.example.com/{z}/{x}/{y}.png',
    );
    await tester.tap(find.byKey(const ValueKey('submit-custom-xyz-tiles')));
    await tester.pumpAndSettle();

    expect(find.text('Topo'), findsOneWidget);
    expect(customBasemaps, hasLength(1));
    expect(customBasemaps.single.styleString, contains('tiles.example.com'));

    await tester.tap(find.text('Topo'));
    await tester.pumpAndSettle();
    expect(find.byType(ActiveBasemapItem), findsOneWidget);
    expect(find.byTooltip('Keluarkan Topo dari Active Layers'), findsOneWidget);

    await tester.tap(find.byTooltip('Keluarkan Topo dari Active Layers'));
    await tester.pumpAndSettle();
    expect(find.byType(ActiveBasemapItem), findsNothing);
    expect(find.byType(ActiveMapItem), findsOneWidget);
  });
}
