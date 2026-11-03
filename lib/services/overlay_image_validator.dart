
import 'dart:typed_data';

class OverlayImageValidator {
  static void validate(String imageFormat, Uint8List bytes) {
    final format = imageFormat.toLowerCase();

    bool valid = false;

    switch (format) {
      case 'png':
        valid = _isPng(bytes);
        break;

      case 'jpg':
      case 'jpeg':
        valid = _isJpeg(bytes);
        break;

      case 'webp':
        valid = _isWebp(bytes);
        break;

      default:
        throw FormatException(
          'Unsupported overlay image format: $imageFormat',
        );
    }

    if (!valid) {
      throw FormatException(
        'Image bytes do not match declared format: $imageFormat',
      );
    }
  }

  static bool _isPng(Uint8List bytes) {
    const signature = [
      0x89, 0x50, 0x4E, 0x47,
      0x0D, 0x0A, 0x1A, 0x0A,
    ];

    if (bytes.length < signature.length) return false;

    for (var i = 0; i < signature.length; i++) {
      if (bytes[i] != signature[i]) return false;
    }

    return true;
  }

  static bool _isJpeg(Uint8List bytes) {
    return bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF;
  }

  static bool _isWebp(Uint8List bytes) {
    if (bytes.length < 12) return false;

    return bytes[0] == 0x52 && // R
        bytes[1] == 0x49 && // I
        bytes[2] == 0x46 && // F
        bytes[3] == 0x46 && // F
        bytes[8] == 0x57 && // W
        bytes[9] == 0x45 && // E
        bytes[10] == 0x42 && // B
        bytes[11] == 0x50; // P
  }
}
