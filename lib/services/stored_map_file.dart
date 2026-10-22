import 'dart:typed_data';

class StoredMapFile {
  final String id;
  final String name;
  final Uint8List bytes;

  const StoredMapFile({
    required this.id,
    required this.name,
    required this.bytes,
  });
}
