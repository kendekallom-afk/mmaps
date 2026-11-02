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
    String extension = 'kmz',
  }) => MapMeta(
    id: id,
    formatVersion: MapMeta.currentFormatVersion,
    name: name,
    originalExtension: extension,
    importedAt: DateTime.utc(2026, 10, 1),
    polygonCount: 3,
    lineCount: 2,
    pointCount: 1,
    bounds: const [118.0, -3.0, 119.0, -2.0],
  );

  setUp(() async {
    supportDirectory = await Directory.systemTemp.createTemp(
      'mmaps_library_test_',
    );
    libraryDirectory = Directory(p.join(supportDirectory.path, 'maps_library'));
    PathProviderPlatform.instance = FakePathProviderPlatform(
      supportDirectory.path,
    );
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
      expect(
        Directory(p.join(libraryDirectory.path, '.tmp')).existsSync(),
        isTrue,
      );
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

    test(
      'replaces existing metadata and keeps the new value readable',
      () async {
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
      },
    );

    test('lists metadata only and skips internal directories', () async {
      await MapLibraryStore.initialize();
      final mapFolder = Directory(p.join(libraryDirectory.path, 'map_001'));
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
      expect(() => MapLibraryStore.readMeta('map_001'), throwsFormatException);
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

    test(
      'rejects symbolic links for metadata, source, GeoJSON and style files',
      () async {
        await MapLibraryStore.initialize();
        final folder = Directory(p.join(libraryDirectory.path, 'map_001'));
        await folder.create(recursive: true);
        await MapLibraryStore.writeMeta(sampleMeta());
        final outside = await Directory.systemTemp.createTemp(
          'mmaps_file_link_',
        );
        addTearDown(() async {
          if (await outside.exists()) await outside.delete(recursive: true);
        });

        Future<void> linkFile(String name) async {
          final external = File(p.join(outside.path, name));
          await external.writeAsString('{}');
          await Link(p.join(folder.path, name)).create(external.path);
        }

        await linkFile('meta.json');
        await expectLater(
          MapLibraryStore.readMeta('map_001'),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          MapLibraryStore.writeMeta(sampleMeta(name: 'Changed')),
          throwsA(isA<FileSystemException>()),
        );
        await Link(p.join(folder.path, 'meta.json')).delete();
        await MapLibraryStore.writeMeta(sampleMeta());

        await linkFile('original.kmz');
        await expectLater(
          MapLibraryStore.readOriginalSource('map_001'),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          MapLibraryStore.writeOriginalSource('map_001', [1, 2]),
          throwsA(isA<FileSystemException>()),
        );
        await Link(p.join(folder.path, 'original.kmz')).delete();

        await linkFile('points.geojson');
        await expectLater(
          MapLibraryStore.readGeoJson('map_001', 'points'),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          MapLibraryStore.writeGeoJson(
            'map_001',
            'points',
            '{"type":"FeatureCollection","features":[]}',
          ),
          throwsA(isA<FileSystemException>()),
        );
        await Link(p.join(folder.path, 'points.geojson')).delete();

        await linkFile('layer_style.json');
        await expectLater(
          MapLibraryStore.readLayerStyle('map_001'),
          throwsA(isA<FileSystemException>()),
        );
        await expectLater(
          MapLibraryStore.writeLayerStyle('map_001', '{}'),
          throwsA(isA<FileSystemException>()),
        );
      },
      skip: Platform.isWindows
          ? 'Windows symlink creation may require Developer Mode or elevation'
          : false,
    );

    test('writes and reads original KMZ bytes', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta());
      final source = [0x50, 0x4b, 0x03, 0x04, 0x10, 0x20];

      await MapLibraryStore.writeOriginalSource('map_001', source);
      final loaded = await MapLibraryStore.readOriginalSource('map_001');

      expect(loaded, source);
      expect(
        await File(p.join(libraryDirectory.path, 'map_001', 'original.kmz'))
            .exists(),
        isTrue,
      );
    });

    test('writes original KML using metadata extension', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta(extension: 'kml'));
      const source = '<kml><Document/></kml>';

      await MapLibraryStore.writeOriginalSource('map_001', source.codeUnits);
      final loaded = await MapLibraryStore.readOriginalSource('map_001');

      expect(String.fromCharCodes(loaded), source);
      expect(
        await File(p.join(libraryDirectory.path, 'map_001', 'original.kml'))
            .exists(),
        isTrue,
      );
    });

    test('reports missing original source clearly', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta());

      expect(MapLibraryStore.readOriginalSource('map_001'), throwsStateError);
    });

    test('rejects writing original source for missing map folder', () async {
      await MapLibraryStore.initialize();
      await expectLater(
        MapLibraryStore.writeOriginalSource('map_001', [1, 2, 3]),
        throwsStateError,
      );
    });

    test('writes and reads all three GeoJSON FeatureCollections', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta());

      const empty = '{"type":"FeatureCollection","features":[]}';
      for (final geometry in ['polygons', 'lines', 'points']) {
        await MapLibraryStore.writeGeoJson('map_001', geometry, empty);
        expect(await MapLibraryStore.readGeoJson('map_001', geometry), empty);
        expect(
          await File(
            p.join(libraryDirectory.path, 'map_001', '$geometry.geojson'),
          ).exists(),
          isTrue,
        );
      }
    });

    test('preserves GeoJSON feature coordinates without modification', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta());
      const source =
          '{"type":"FeatureCollection","features":['
          '{"type":"Feature","properties":{},"geometry":{"type":"LineString",'
          '"coordinates":[[118.123456789,-2.123456789],[119.987654321,-3.987654321]]}}]}';

      await MapLibraryStore.writeGeoJson('map_001', 'lines', source);
      expect(await MapLibraryStore.readGeoJson('map_001', 'lines'), source);
    });

    test('rejects invalid geometry names and malformed GeoJSON', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta());

      expect(
        () => MapLibraryStore.writeGeoJson('map_001', 'roads', '{}'),
        throwsFormatException,
      );
      expect(
        () => MapLibraryStore.writeGeoJson(
          'map_001',
          'points',
          '{"type":"FeatureCollection"}',
        ),
        throwsFormatException,
      );
    });

    test('reports a missing GeoJSON file clearly', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta());

      expect(
        MapLibraryStore.readGeoJson('map_001', 'polygons'),
        throwsStateError,
      );
    });

    test('writes and reads per-map layer style JSON', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta());
      const style =
          '{"polygon":{"fill":"#338855","opacity":0.4},'
          '"line":{"color":"#112233","width":2},"point":{"visible":true}}';

      await MapLibraryStore.writeLayerStyle('map_001', style);
      expect(await MapLibraryStore.readLayerStyle('map_001'), style);
      expect(
        await File(p.join(libraryDirectory.path, 'map_001', 'layer_style.json'))
            .exists(),
        isTrue,
      );
    });

    test('rejects malformed or non-object layer style JSON', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta());

      expect(
        () => MapLibraryStore.writeLayerStyle('map_001', '{broken'),
        throwsFormatException,
      );
      expect(
        () => MapLibraryStore.writeLayerStyle('map_001', '[]'),
        throwsFormatException,
      );
    });

    test('reports missing layer style clearly', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta());

      expect(MapLibraryStore.readLayerStyle('map_001'), throwsStateError);
    });

    test(
      'replaces an existing original source without losing the new bytes',
      () async {
        await MapLibraryStore.initialize();
        await Directory(p.join(libraryDirectory.path, 'map_001'))
            .create(recursive: true);
        await MapLibraryStore.writeMeta(sampleMeta());

        await MapLibraryStore.writeOriginalSource('map_001', [1, 2, 3]);
        await MapLibraryStore.writeOriginalSource('map_001', [9, 8, 7, 6]);

        expect(await MapLibraryStore.readOriginalSource('map_001'), [
          9,
          8,
          7,
          6,
        ]);
      },
    );

    test('replaces an existing GeoJSON file and preserves exact content', () async {
      await MapLibraryStore.initialize();
      await Directory(p.join(libraryDirectory.path, 'map_001'))
          .create(recursive: true);
      await MapLibraryStore.writeMeta(sampleMeta());

      const oldContent = '{"type":"FeatureCollection","features":[]}';
      const newContent =
          '{"type":"FeatureCollection","features":[{"type":"Feature","properties":{"v":2},"geometry":null}]}';
      await MapLibraryStore.writeGeoJson('map_001', 'points', oldContent);
      await MapLibraryStore.writeGeoJson('map_001', 'points', newContent);

      expect(
        await MapLibraryStore.readGeoJson('map_001', 'points'),
        newContent,
      );
    });

    test(
      'replaces an existing layer style file and preserves exact content',
      () async {
        await MapLibraryStore.initialize();
        await Directory(p.join(libraryDirectory.path, 'map_001'))
            .create(recursive: true);
        await MapLibraryStore.writeMeta(sampleMeta());

        const oldStyle = '{"version":1}';
        const newStyle = '{"version":2,"visible":false}';
        await MapLibraryStore.writeLayerStyle('map_001', oldStyle);
        await MapLibraryStore.writeLayerStyle('map_001', newStyle);

        expect(await MapLibraryStore.readLayerStyle('map_001'), newStyle);
      },
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

      expect(
        () => MapLibraryStore.readMeta('../escape'),
        throwsFormatException,
      );
    });

    test('startup restores backup when target file is missing', () async {
      final folder = Directory(p.join(libraryDirectory.path, 'map_001'));
      await folder.create(recursive: true);
      final backup = File(p.join(folder.path, 'meta.json.backup-100'));
      await backup.writeAsString(
        jsonEncode(sampleMeta(name: 'Recovered').toJson()),
      );

      await MapLibraryStore.initialize();

      expect((await MapLibraryStore.readMeta('map_001')).name, 'Recovered');
      expect(await backup.exists(), isFalse);
    });

    test(
      'startup keeps existing target and removes stale backup and temp',
      () async {
        final folder = Directory(p.join(libraryDirectory.path, 'map_001'));
        await folder.create(recursive: true);
        final target = File(p.join(folder.path, 'meta.json'));
        final backup = File(p.join(folder.path, 'meta.json.backup-100'));
        final temporary = File(p.join(folder.path, 'meta.json.tmp'));
        await target.writeAsString(
          jsonEncode(sampleMeta(name: 'Current').toJson()),
        );
        await backup.writeAsString(
          jsonEncode(sampleMeta(name: 'Old').toJson()),
        );
        await temporary.writeAsString('incomplete');

        await MapLibraryStore.initialize();

        expect((await MapLibraryStore.readMeta('map_001')).name, 'Current');
        expect(await backup.exists(), isFalse);
        expect(await temporary.exists(), isFalse);
      },
    );

    test('startup cleans abandoned staging and deleting folders', () async {
      final staging = Directory(
        p.join(libraryDirectory.path, '.tmp', 'map_001-nonce'),
      );
      final deleting = Directory(
        p.join(libraryDirectory.path, '.deleting', 'map_002-nonce'),
      );
      await staging.create(recursive: true);
      await deleting.create(recursive: true);
      await File(p.join(staging.path, 'partial')).writeAsString('partial');
      await File(p.join(deleting.path, 'old')).writeAsString('old');

      await MapLibraryStore.initialize();

      expect(
        await Directory(p.join(libraryDirectory.path, '.tmp')).list().isEmpty,
        isTrue,
      );

      expect(
        await Directory(p.join(libraryDirectory.path, '.deleting'))
            .list()
            .isEmpty,
        isTrue,
      );
    });

    test('startup restores active index backup if target is missing', () async {
      final backup = File(
        p.join(libraryDirectory.path, 'active_layers.json.backup-100'),
      );
      await libraryDirectory.create(recursive: true);
      await backup.writeAsString(jsonEncode(['map_001']));

      await MapLibraryStore.initialize();

      expect((await MapLibraryStore.readActiveMapIndex()).mapIds, ['map_001']);
      expect(await backup.exists(), isFalse);
    });
    test('startup ignores unknown backup files', () async {
      final unknownBackup = File(
        p.join(libraryDirectory.path, 'file_asing.backup-123456'),
      );

      await libraryDirectory.create(recursive: true);
      await unknownBackup.writeAsString('data asing');

      await MapLibraryStore.initialize();

      expect(
        await unknownBackup.exists(),
        isTrue,
        reason: 'Unknown backup files must not be modified',
      );

      expect(
        await File(p.join(libraryDirectory.path, 'file_asing')).exists(),
        isFalse,
      );
    });

    test('startup rejects backup when target is a directory', () async {
      final mapFolder = Directory(p.join(libraryDirectory.path, 'map_001'));

      final target = Directory(p.join(mapFolder.path, 'meta.json'));

      final backup = File(p.join(mapFolder.path, 'meta.json.backup-123456'));

      await mapFolder.create(recursive: true);
      await target.create(recursive: true);
      await backup.writeAsString('backup data');

      await expectLater(
        MapLibraryStore.initialize(),
        throwsA(isA<FileSystemException>()),
      );

      expect(await target.exists(), isTrue);
      expect(await backup.exists(), isTrue);
    });
  });
}
