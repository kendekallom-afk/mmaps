import 'dart:convert';

import '../models/map_library_item.dart';
import '../models/map_library_active_index.dart';
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

final List<String> _activeMapIds = [];
final Map<String, List<int>> _originalSources = {};

Future<MapLibraryActiveIndex> readActiveMapIndex() async {
  final orphans = _activeMapIds.where((id) => !_metadata.containsKey(id)).toList();
  return MapLibraryActiveIndex(mapIds: _activeMapIds, orphanIds: orphans);
}

Future<void> writeActiveMapIds(List<String> ids) async {
  final seen = <String>{};
  for (final id in ids) {
    if (!MapMeta.isValidId(id)) throw FormatException('Invalid active map ID: $id');
    if (!seen.add(id)) throw FormatException('Duplicate active map ID: $id');
  }
  _activeMapIds
    ..clear()
    ..addAll(ids);
}

Future<List<int>> readOriginalSource(String id) async {
  if (!MapMeta.isValidId(id)) throw FormatException('Invalid map ID: $id');
  if (!_metadata.containsKey(id)) throw StateError('Map not found: $id');
  final bytes = _originalSources[id];
  if (bytes == null) throw StateError('Original source not found for map: $id');
  return List<int>.unmodifiable(bytes);
}

Future<void> writeOriginalSource(String id, List<int> bytes) async {
  if (!MapMeta.isValidId(id)) throw FormatException('Invalid map ID: $id');
  final meta = _metadata[id];
  if (meta == null) throw StateError('Map not found: $id');
  final extension = meta.originalExtension.toLowerCase();
  if (extension != 'kml' && extension != 'kmz') {
    throw FormatException('Unsupported original source extension: $extension');
  }
  _originalSources[id] = List<int>.unmodifiable(bytes);
}

final Map<String, Map<String, String>> _geoJsonFiles = {};

String _geoJsonKey(String geometry) {
  if (geometry != 'polygons' && geometry != 'lines' && geometry != 'points') {
    throw FormatException('Unsupported geometry type: $geometry');
  }
  return geometry;
}

void _validateFeatureCollection(String content) {
  final decoded = jsonDecode(content);
  if (decoded is! Map<String, dynamic> ||
      decoded['type'] != 'FeatureCollection' ||
      decoded['features'] is! List) {
    throw const FormatException(
      'GeoJSON must be a FeatureCollection with a features array',
    );
  }
}

Future<String> readGeoJson(String id, String geometry) async {
  if (!MapMeta.isValidId(id)) throw FormatException('Invalid map ID: $id');
  if (!_metadata.containsKey(id)) throw StateError('Map not found: $id');
  final key = _geoJsonKey(geometry);
  final content = _geoJsonFiles[id]?[key];
  if (content == null) throw StateError('$key GeoJSON not found for map: $id');
  _validateFeatureCollection(content);
  return content;
}

Future<void> writeGeoJson(String id, String geometry, String content) async {
  if (!MapMeta.isValidId(id)) throw FormatException('Invalid map ID: $id');
  if (!_metadata.containsKey(id)) throw StateError('Map not found: $id');
  final key = _geoJsonKey(geometry);
  _validateFeatureCollection(content);
  (_geoJsonFiles[id] ??= {})[key] = content;
}

final Map<String, String> _layerStyles = {};

void _validateLayerStyle(String content) {
  final decoded = jsonDecode(content);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('layer_style.json must contain a JSON object');
  }
}

Future<String> readLayerStyle(String id) async {
  if (!MapMeta.isValidId(id)) throw FormatException('Invalid map ID: $id');
  if (!_metadata.containsKey(id)) throw StateError('Map not found: $id');
  final content = _layerStyles[id];
  if (content == null) throw StateError('layer_style.json not found for map: $id');
  _validateLayerStyle(content);
  return content;
}

Future<void> writeLayerStyle(String id, String content) async {
  if (!MapMeta.isValidId(id)) throw FormatException('Invalid map ID: $id');
  if (!_metadata.containsKey(id)) throw StateError('Map not found: $id');
  _validateLayerStyle(content);
  _layerStyles[id] = content;
}
