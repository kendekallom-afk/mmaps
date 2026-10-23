// ignore_for_file: depend_on_referenced_packages

import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:mmaps_flutter/services/map_file_store.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

class FakePathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String path;
  FakePathProviderPlatform(this.path);

  @override
  Future<String?> getApplicationSupportPath() async => path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('mmaps_test_');
    PathProviderPlatform.instance = FakePathProviderPlatform(tempDir.path);
  });

  tearDownAll(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('MapFileStore lazy loading tests', () {
    test('listStoredMapFiles returns metadata and readStoredMapFile reads bytes', () async {
      final sampleBytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final file = StoredMapFile(
        id: 'file-123',
        name: 'test_layer.kml',
        bytes: sampleBytes,
      );

      // Save file
      await MapFileStore.save(file);

      // List stored files (only metadata, size = 5, no bytes loaded directly)
      final files = await MapFileStore.listStoredMapFiles();
      expect(files.any((f) => f.id == 'file-123'), isTrue);

      final fileInfo = files.firstWhere((f) => f.id == 'file-123');
      expect(fileInfo.name, 'test_layer.kml');
      expect(fileInfo.size, 5);

      // Read stored file on demand
      final loadedBytes = await MapFileStore.readStoredMapFile('file-123');
      expect(loadedBytes, equals(sampleBytes));

      // Clean up
      await MapFileStore.remove('file-123');
      final afterRemove = await MapFileStore.listStoredMapFiles();
      expect(afterRemove.any((f) => f.id == 'file-123'), isFalse);
    });
  });
}
