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

    test('replaces existing metadata and keeps the new value readable', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);

      await MapLibraryStore.writeMeta(sampleMeta(name: 'Nama Lama'));
      await MapLibraryStore.writeMeta(sampleMeta(name: 'Nama Baru'));

      final loaded = await MapLibraryStore.readMeta('map_001');
      expect(loaded.name, 'Nama Baru');
      expect(
        await File(p.join(libraryDirectory.path, 'map_001', 'meta.json'))
            .exists(),
        isTrue,
      );
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

    test('reports malformed metadata as a damaged map entry', () async {
      await MapLibraryStore.initialize();
      final folder = Directory(p.join(libraryDirectory.path, 'broken_json'));
      await folder.create(recursive: true);
      await File(p.join(folder.path, 'meta.json'))
          .writeAsString('{ this is not valid JSON');

      final items = await MapLibraryStore.listMaps();

      expect(items, hasLength(1));
      expect(items.single.folderId, 'broken_json');
      expect(items.single.isValid, isFalse);
    });

    test('reports folders with invalid IDs instead of opening them', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'Invalid-ID'))
          .create(recursive: true);

      final items = await MapLibraryStore.listMaps();

      expect(items, hasLength(1));
      expect(items.single.folderId, 'Invalid-ID');
      expect(items.single.isValid, isFalse);
    });

    test(
      'rejects a map folder symbolic link that points outside the library',
      () async {
        await MapLibraryStore.initialize();
        final outside = await Directory.systemTemp.createTemp('mmaps_outside_');
        addTearDown(() async {
          if (await outside.exists()) await outside.delete(recursive: true);
        });

        final outsideMap = Directory(p.join(outside.path, 'map_001'));
        await outsideMap.create(recursive: true);
        await File(p.join(outsideMap.path, 'meta.json'))
            .writeAsString(jsonEncode(sampleMeta().toJson()));

        final link = Link(p.join(libraryDirectory.path, 'map_001'));
        await link.create(outsideMap.path);

        expect(
          () => MapLibraryStore.readMeta('map_001'),
          throwsFormatException,
        );
      },
      skip: Platform.isWindows
          ? 'Windows symlink creation may require Developer Mode or elevation'
          : false,
    );

    test('reads empty active index when no file exists', () async {
      await MapLibraryStore.initialize();
      final index = await MapLibraryStore.readActiveMapIndex();
      expect(index.mapIds, isEmpty);
      expect(index.orphanIds, isEmpty);
    });

    test('writes and reads active IDs and reports orphan IDs', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta());
      await MapLibraryStore.writeActiveMapIds(['map_001', 'map_missing']);

      final index = await MapLibraryStore.readActiveMapIndex();
      expect(index.mapIds, ['map_001', 'map_missing']);
      expect(index.orphanIds, ['map_missing']);
    });

    test('reports corrupt active index and refuses to overwrite it', () async {
      await MapLibraryStore.initialize();
      final file = File(p.join(libraryDirectory.path, 'active_layers.json'));
      await file.writeAsString('{broken');

      expect(MapLibraryStore.readActiveMapIndex(), throwsFormatException);
      expect(
        () => MapLibraryStore.writeActiveMapIds(['map_001']),
        throwsFormatException,
      );
      expect(await file.readAsString(), '{broken');
    });

    test('rejects duplicate and invalid active IDs', () async {
      await MapLibraryStore.initialize();
      expect(
        () => MapLibraryStore.writeActiveMapIds(['map_001', 'map_001']),
        throwsFormatException,
      );
      expect(
        () => MapLibraryStore.writeActiveMapIds(['../outside']),
        throwsFormatException,
      );
    });

    test('rejects invalid IDs before accessing storage', () async {
      await MapLibraryStore.initialize();

      expect(() => MapLibraryStore.readMeta('../escape'), throwsFormatException);
    });
  });
}
