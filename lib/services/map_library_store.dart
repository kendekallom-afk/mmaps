import '../models/map_meta.dart';
import '../models/map_library_item.dart';
import 'map_library_store_memory.dart'
    if (dart.library.io) 'map_library_store_io.dart' as backend;

export '../models/map_library_item.dart';

/// Folder-based map storage. This is intentionally separate from the
/// legacy single-file MapFileStore during the migration period.
abstract final class MapLibraryStore {
  /// Creates the library root and its internal working directories.
  static Future<void> initialize() => backend.initializeLibrary();

  /// Lists map folders by reading metadata only. Invalid folders are returned
  /// as issue entries instead of being silently ignored.
  static Future<List<MapLibraryItem>> listMaps() => backend.listMaps();

  /// Reads and validates one map's metadata.
  static Future<MapMeta> readMeta(String id) => backend.readMeta(id);

  /// Writes metadata to an existing map folder. This does not create or
  /// replace a map folder; folder creation belongs to the importer stage.
  static Future<void> writeMeta(MapMeta meta) => backend.writeMeta(meta);
}
