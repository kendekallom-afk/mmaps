import 'package:flutter_test/flutter_test.dart';
import 'package:mmaps_flutter/models/map_meta.dart';

void main() {
  final importedAt = DateTime.utc(2026, 10, 30, 10);

  MapMeta createMeta({
    String id = 'map_123',
    String extension = 'kmz',
    List<double> bounds = const [118.0, -3.0, 119.0, -2.0],
  }) {
    return MapMeta(
      id: id,
      formatVersion: MapMeta.currentFormatVersion,
      name: 'Peta Kawasan',
      originalExtension: extension,
      importedAt: importedAt,
      polygonCount: 12,
      lineCount: 3,
      pointCount: 4,
      bounds: bounds,
    );
  }

  group('MapMeta', () {
    test('serializes and restores metadata', () {
      final original = createMeta();
      final restored = MapMeta.fromJson(original.toJson());

      expect(restored.id, original.id);
      expect(restored.name, original.name);
      expect(restored.originalExtension, 'kmz');
      expect(restored.polygonCount, 12);
      expect(restored.lineCount, 3);
      expect(restored.pointCount, 4);
      expect(restored.bounds, [118.0, -3.0, 119.0, -2.0]);
      expect(restored.importedAt, importedAt);
    });

    test('accepts valid lowercase IDs up to 64 characters', () {
      expect(MapMeta.isValidId('map_123'), isTrue);
      expect(MapMeta.isValidId('a'), isTrue);
      expect(MapMeta.isValidId('a' * 64), isTrue);
    });

    test('rejects invalid and reserved IDs', () {
      for (final id in [
        '',
        '.hidden',
        '-map',
        'MapA',
        'map/name',
        r'map\name',
        'map..',
        'a' * 65,
        '.tmp',
        '.deleting',
        'active_layers',
      ]) {
        expect(() => createMeta(id: id), throwsFormatException, reason: id);
      }
    });

    test('rejects unsupported extension and negative feature counts', () {
      expect(
        () => createMeta(extension: 'zip'),
        throwsFormatException,
      );
      expect(
        () => MapMeta(
          id: 'map_1',
          formatVersion: 1,
          name: 'Peta',
          originalExtension: 'kml',
          importedAt: importedAt,
          polygonCount: -1,
          lineCount: 0,
          pointCount: 0,
          bounds: const [118, -3, 119, -2],
        ),
        throwsFormatException,
      );
    });

    test('rejects invalid bounds order, range, and length', () {
      expect(
        () => createMeta(bounds: const [119, -3, 118, -2]),
        throwsFormatException,
      );
      expect(
        () => createMeta(bounds: const [118, -91, 119, -2]),
        throwsFormatException,
      );
      expect(
        () => createMeta(bounds: const [118, -3, 119]),
        throwsFormatException,
      );
    });

    test('rejects malformed JSON field types', () {
      final json = createMeta().toJson()..['featureCounts'] = 'invalid';
      expect(() => MapMeta.fromJson(json), throwsFormatException);
    });

    test('bounds cannot be modified through the exposed list', () {
      final meta = createMeta();
      expect(
        () => meta.bounds[0] = 0,
        throwsUnsupportedError,
      );
    });
  });
}
