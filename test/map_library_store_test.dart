// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mmaps_flutter/models/map_meta.dart';
import 'package:mmaps_flutter/services/map_library_store.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  FakePathProviderPlatform(this.path);

  final String path;

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory supportDirectory;
  late Directory libraryDirectory;

  MapMeta sampleMeta({
    String id = 'map_001',
    String name = 'Peta Uji',
  }) =>
      MapMeta(
        id: id,
        formatVersion: MapMeta.currentFormatVersion,
        name: name,
        originalExtension: 'kmz',
        importedAt: DateTime.utc(2026, 10, 1),
        polygonCount: 3,
        lineCount: 2,
        pointCount: 1,
        bounds: const [118.0, -3.0, 119.0, -2.0],
      );

  setUp(() async {
    supportDirectory =
        await Directory.systemTemp.createTemp('mmaps_library_test_');
    libraryDirectory = Directory(p.join(supportDirectory.path, 'maps_library'));
    PathProviderPlatform.instance =
        FakePathProviderPlatform(supportDirectory.path);
  });

  tearDown(() async {
    if (await supportDirectory.exists()) {
      await supportDirectory.delete(recursive: true);
    }
  });

  group('MapLibraryStore basic storage', () {
    test('initialize creates root and internal directories', () async {
      await MapLibraryStore.initialize();

      expect(await libraryDirectory.exists(), isTrue);
      expect(Directory(p.join(libraryDirectory.path, '.tmp')).existsSync(),
          isTrue);
      expect(
        Directory(p.join(libraryDirectory.path, '.deleting')).existsSync(),
        isTrue,
      );
    });

    test('writes and reads metadata in an existing map folder', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);

      await MapLibraryStore.writeMeta(sampleMeta());
      final loaded = await MapLibraryStore.readMeta('map_001');

      expect(loaded.id, 'map_001');
      expect(loaded.name, 'Peta Uji');
      expect(loaded.polygonCount, 3);
    });

    test('lists metadata only and skips internal directories', () async {
      await MapLibraryStore.initialize();
      final mapFolder =
          Directory(p.join(libraryDirectory.path, 'map_001'));
      await mapFolder.create(recursive: true);
      await File(p.join(mapFolder.path, 'polygons.geojson'))
          .writeAsString('this is deliberately not valid JSON');
      await MapLibraryStore.writeMeta(sampleMeta());

      final items = await MapLibraryStore.listMaps();

      expect(items, hasLength(1));
      expect(items.single.isValid, isTrue);
      expect(items.single.meta!.id, 'map_001');
    });

    test('reports a folder with missing metadata as an issue', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'broken_map'))
          .create(recursive: true);

      final items = await MapLibraryStore.listMaps();

      expect(items, hasLength(1));
      expect(items.single.isValid, isFalse);
      expect(items.single.folderId, 'broken_map');
    });

    test('rejects metadata whose ID differs from its folder', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await File(p.join(libraryDirectory.path, 'map_001', 'meta.json'))
          .writeAsString(jsonEncode(sampleMeta(id: 'map_002').toJson()));

      final items = await MapLibraryStore.listMaps();

      expect(items.single.isValid, isFalse);
      expect(
        () => MapLibraryStore.readMeta('map_001'),
        throwsFormatException,
      );
    });

    test('rejects invalid IDs before accessing storage', () async {
      await MapLibraryStore.initialize();

      expect(() => MapLibraryStore.readMeta('../escape'), throwsFormatException);
    });
  });
}
