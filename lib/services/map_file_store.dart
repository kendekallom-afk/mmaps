import 'dart:typed_data';

import 'stored_map_file.dart';
import 'map_file_store_memory.dart'
    if (dart.library.io) 'map_file_store_io.dart'
    as backend;

export 'stored_map_file.dart';

abstract final class MapFileStore {
  /// Mengembalikan daftar metadata file yang tersimpan (id, name, size)
  /// tanpa memuat data bytes ke RAM (cepat & ringan).
  static Future<List<StoredMapFileInfo>> listStoredMapFiles() =>
      backend.listStoredMapFiles();

  /// Alias singkat untuk [listStoredMapFiles]
  static Future<List<StoredMapFileInfo>> listFiles() =>
      backend.listStoredMapFiles();

  /// Membaca data bytes file berdasarkan [id] secara on-demand / lazy.
  static Future<Uint8List> readStoredMapFile(String id) =>
      backend.readStoredMapFile(id);

  /// Alias singkat untuk [readStoredMapFile]
  static Future<Uint8List> readFile(String id) =>
      backend.readStoredMapFile(id);

  /// Memuat semua file beserta bytes (dipertahankan untuk kompatibilitas)
  static Future<List<StoredMapFile>> load() => backend.loadStoredMapFiles();

  static Future<void> save(StoredMapFile file) =>
      backend.saveStoredMapFile(file);

  static Future<void> remove(String id) => backend.removeStoredMapFile(id);

  static Future<Set<String>> loadActiveIds() => backend.loadStoredActiveIds();

  static Future<void> saveActiveIds(Set<String> ids) =>
      backend.saveStoredActiveIds(ids);
}
