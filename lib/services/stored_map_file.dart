import 'dart:typed_data';

/// Metadata ringkas file peta yang tersimpan tanpa memuat bytes ke RAM
class StoredMapFileInfo {
  final String id;
  final String name;
  final int size;

  const StoredMapFileInfo({
    required this.id,
    required this.name,
    required this.size,
  });
}

/// Representasi file peta lengkap beserta data bytes
class StoredMapFile {
  final String id;
  final String name;
  final Uint8List bytes;

  const StoredMapFile({
    required this.id,
    required this.name,
    required this.bytes,
  });

  int get size => bytes.lengthInBytes;

  StoredMapFileInfo toInfo() => StoredMapFileInfo(
        id: id,
        name: name,
        size: size,
      );
}
