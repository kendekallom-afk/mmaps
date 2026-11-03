import 'dart:typed_data';
import '../models/map_meta.dart';
import '../models/map_library_item.dart';
import '../models/map_library_active_index.dart';
import 'map_library_store_memory.dart'
    if (dart.library.io) 'map_library_store_io.dart' as backend;
import '../models/map_overlay_manifest.dart';

export '../models/map_library_item.dart';
export '../models/map_library_active_index.dart';

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

  /// Reads the original KML/KMZ source bytes for a map.
  static Future<List<int>> readOriginalSource(String id) =>
      backend.readOriginalSource(id);

  /// Writes the original KML/KMZ source using the extension in map metadata.
  static Future<void> writeOriginalSource(String id, List<int> bytes) =>
      backend.writeOriginalSource(id, bytes);

  /// Reads one geometry GeoJSON file (polygons, lines, or points).
  static Future<String> readGeoJson(String id, String geometry) =>
      backend.readGeoJson(id, geometry);

  /// Writes one valid GeoJSON FeatureCollection for the selected geometry.
  static Future<void> writeGeoJson(
    String id,
    String geometry,
    String content,
  ) => backend.writeGeoJson(id, geometry, content);

  /// Reads the per-map MapLibre layer style JSON.
  static Future<String> readLayerStyle(String id) =>
      backend.readLayerStyle(id);

  /// Writes a per-map MapLibre layer style JSON object.
  static Future<void> writeLayerStyle(String id, String content) =>
      backend.writeLayerStyle(id, content);

  /// Reads active IDs and reports valid IDs whose map folders are missing.
  static Future<MapLibraryActiveIndex> readActiveMapIndex() =>
      backend.readActiveMapIndex();

  /// Replaces the active ID list. Corrupt existing data is never silently reset.
  static Future<void> writeActiveMapIds(List<String> ids) =>
      backend.writeActiveMapIds(ids);

  /// Reads the GroundOverlay manifest for one map.
  /// Returns an empty manifest when the map has no overlays.
  static Future<MapOverlayManifest> readOverlayManifest(String id) =>
      backend.readOverlayManifest(id);

  /// Writes the GroundOverlay manifest for one map.
  static Future<void> writeOverlayManifest(
    String id,
    MapOverlayManifest manifest,
  ) => backend.writeOverlayManifest(id, manifest);

    /// Writes the original overlay image bytes without modification.
  static Future<void> writeOverlayAsset(
    String id,
    String fileName,
    Uint8List bytes,
  ) => backend.writeOverlayAsset(id, fileName, bytes);

  /// Reads the original overlay image bytes.
  static Future<Uint8List> readOverlayAsset(
    String id,
    String fileName,
  ) => backend.readOverlayAsset(id, fileName);
}
