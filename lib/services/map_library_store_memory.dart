import '../models/map_library_item.dart';
import '../models/map_meta.dart';

final Map<String, MapMeta> _metadata = {};

Future<void> initializeLibrary() async {}

Future<List<MapLibraryItem>> listMaps() async {
  final items = _metadata.values
      .map(MapLibraryItem.valid)
      .toList()
    ..sort((a, b) => a.folderId.compareTo(b.folderId));
  return List.unmodifiable(items);
}

Future<MapMeta> readMeta(String id) async {
  if (!MapMeta.isValidId(id)) {
    throw FormatException('Invalid map ID: $id');
  }
  final meta = _metadata[id];
  if (meta == null) throw StateError('Map not found: $id');
  return meta;
}

Future<void> writeMeta(MapMeta meta) async {
  _metadata[meta.id] = meta;
}
