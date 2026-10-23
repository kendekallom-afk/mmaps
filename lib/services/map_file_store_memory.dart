import 'dart:typed_data';

import 'stored_map_file.dart';

final Map<String, StoredMapFile> _files = {};
Set<String> _activeIds = {};

/// Mengembalikan daftar metadata file di memori tanpa duplikasi bytes
Future<List<StoredMapFileInfo>> listStoredMapFiles() async {
  final list = _files.values
      .map(
        (file) => StoredMapFileInfo(
          id: file.id,
          name: file.name,
          size: file.bytes.lengthInBytes,
        ),
      )
      .toList();
  list.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return list;
}

/// Membaca bytes file berdasarkan [id]
Future<Uint8List> readStoredMapFile(String id) async {
  final file = _files[id];
  if (file == null) {
    throw StateError('File peta dengan ID $id tidak ditemukan.');
  }
  return file.bytes;
}

Future<List<StoredMapFile>> loadStoredMapFiles() async =>
    List.unmodifiable(_files.values);

Future<void> saveStoredMapFile(StoredMapFile file) async {
  _files[file.id] = file;
}

Future<void> removeStoredMapFile(String id) async {
  _files.remove(id);
  _activeIds.remove(id);
}

Future<Set<String>> loadStoredActiveIds() async => Set.of(_activeIds);

Future<void> saveStoredActiveIds(Set<String> ids) async {
  _activeIds = Set.of(ids);
}
