
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mmaps_flutter/models/map_overlay_manifest.dart';

void main() {
  MapOverlayAsset sampleOverlay({
    String id = 'overlay_0001',
    String file = 'overlay_0001.png',
    String format = 'png',
  }) {
    return MapOverlayAsset(
      id: id,
      name: 'Peta Tutupan Lahan',
      file: file,
      imageFormat: format,
      bounds: const MapOverlayBounds(
        north: -2.45123456789,
        south: -2.48123456789,
        east: 119.35123456789,
        west: 119.31123456789,
      ),
    );
  }

  group('MapOverlayManifest', () {
    test('serializes and reads overlay manifest', () {
      final manifest = MapOverlayManifest(
        overlays: [sampleOverlay()],
      );

      final encoded = jsonEncode(manifest.toJson());
      final decoded = MapOverlayManifest.fromJson(
        jsonDecode(encoded),
      );

      expect(decoded.overlays, hasLength(1));
      expect(decoded.overlays.first.id, 'overlay_0001');
      expect(decoded.overlays.first.imageFormat, 'png');
    });

    test('preserves bounds precision', () {
      final manifest = MapOverlayManifest(
        overlays: [sampleOverlay()],
      );

      final restored = MapOverlayManifest.fromJson(
        jsonDecode(jsonEncode(manifest.toJson())),
      );

      expect(
        restored.overlays.first.bounds.north,
        -2.45123456789,
      );

      expect(
        restored.overlays.first.bounds.west,
        119.31123456789,
      );
    });

    test('supports empty manifest', () {
      final manifest = MapOverlayManifest(overlays: []);

      expect(manifest.toJson(), {'overlays': []});
    });

    test('rejects duplicate overlay IDs', () {
      expect(
        () => MapOverlayManifest(
          overlays: [
            sampleOverlay(),
            sampleOverlay(file: 'overlay_0002.png'),
          ],
        ),
        throwsFormatException,
      );
    });

    test('rejects duplicate filenames', () {
      expect(
        () => MapOverlayManifest(
          overlays: [
            sampleOverlay(),
            sampleOverlay(id: 'overlay_0002'),
          ],
        ),
        throwsFormatException,
      );
    });

    test('rejects path traversal in filename', () {
      expect(
        () => sampleOverlay(
          file: '../outside.png',
        ).validate(),
        throwsFormatException,
      );
    });

    test('rejects unsupported image format', () {
      expect(
        () => sampleOverlay(
          file: 'overlay_0001.gif',
          format: 'gif',
        ).validate(),
        throwsFormatException,
      );
    });

    test('rejects invalid geographic bounds', () {
      expect(
        () => MapOverlayBounds(
          north: -3,
          south: -2,
          east: 119,
          west: 118,
        ).validate(),
        throwsFormatException,
      );
    });

    test('allows bounds crossing the international date line', () {
      expect(
        () => const MapOverlayBounds(
          north: 10,
          south: -10,
          east: -170,
          west: 170,
        ).validate(),
        returnsNormally,
      );
    });
  });
}
