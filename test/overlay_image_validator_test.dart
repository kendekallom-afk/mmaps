
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mmaps_flutter/services/overlay_image_validator.dart';

void main() {
  group('OverlayImageValidator', () {
    test('accepts valid PNG signature', () {
      final bytes = Uint8List.fromList([
        0x89, 0x50, 0x4E, 0x47,
        0x0D, 0x0A, 0x1A, 0x0A,
      ]);

      expect(
        () => OverlayImageValidator.validate('png', bytes),
        returnsNormally,
      );
    });

    test('accepts valid JPEG signature', () {
      final bytes = Uint8List.fromList([
        0xFF, 0xD8, 0xFF,
      ]);

      expect(
        () => OverlayImageValidator.validate('jpg', bytes),
        returnsNormally,
      );
    });

    test('accepts valid WebP signature', () {
      final bytes = Uint8List.fromList([
        0x52, 0x49, 0x46, 0x46,
        0x00, 0x00, 0x00, 0x00,
        0x57, 0x45, 0x42, 0x50,
      ]);

      expect(
        () => OverlayImageValidator.validate('webp', bytes),
        returnsNormally,
      );
    });

    test('rejects JPEG bytes declared as PNG', () {
      final bytes = Uint8List.fromList([
        0xFF, 0xD8, 0xFF,
      ]);

      expect(
        () => OverlayImageValidator.validate('png', bytes),
        throwsFormatException,
      );
    });

    test('rejects empty image bytes', () {
      final bytes = Uint8List(0);

      expect(
        () => OverlayImageValidator.validate('png', bytes),
        throwsFormatException,
      );
    });

    test('rejects unsupported image format', () {
      final bytes = Uint8List.fromList([1, 2, 3]);

      expect(
        () => OverlayImageValidator.validate('gif', bytes),
        throwsFormatException,
      );
    });

    test('rejects corrupted PNG signature', () {
      final bytes = Uint8List.fromList([
        0x89, 0x50, 0x00, 0x47,
        0x0D, 0x0A, 0x1A, 0x0A,
      ]);

      expect(
        () => OverlayImageValidator.validate('png', bytes),
        throwsFormatException,
      );
    });
  });
}
