import 'stored_map_file.dart';
import 'map_file_store_memory.dart'
    if (dart.library.io) 'map_file_store_io.dart'
    as backend;

export 'stored_map_file.dart';

abstract final class MapFileStore {
  static Future<List<StoredMapFile>> load() => backend.loadStoredMapFiles();

  static Future<void> save(StoredMapFile file) =>
      backend.saveStoredMapFile(file);

  static Future<void> remove(String id) => backend.removeStoredMapFile(id);

  static Future<Set<String>> loadActiveIds() => backend.loadStoredActiveIds();

  static Future<void> saveActiveIds(Set<String> ids) =>
      backend.saveStoredActiveIds(ids);
}
