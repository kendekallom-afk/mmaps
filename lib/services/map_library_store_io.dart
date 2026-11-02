import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/map_library_item.dart';
import '../models/map_meta.dart';

Future<Directory> _rootDirectory() async {
  final support = await getApplicationSupportDirectory();
  return Directory(p.join(support.path, 'maps_library'));
}

Future<void> initializeLibrary() async {
  final root = await _rootDirectory();
  await root.create(recursive: true);
  await Directory(p.join(root.path, '.tmp')).create(recursive: true);
  await Directory(p.join(root.path, '.deleting')).create(recursive: true);
}

Future<String> _validatedMapPath(String id) async {
  if (!MapMeta.isValidId(id)) {
    throw FormatException('Invalid map ID: $id');
  }

  final root = await _rootDirectory();
  await root.create(recursive: true);
  final canonicalRoot = await root.resolveSymbolicLinks();
  final candidate = Directory(p.join(canonicalRoot, id));
  final resolved = p.normalize(candidate.absolute.path);
  final expectedPrefix = p.normalize(canonicalRoot + Platform.pathSeparator);

  if (!resolved.startsWith(expectedPrefix)) {
    throw FormatException('Map path escapes library root: $id');
  }
  return resolved;
}

Future<List<MapLibraryItem>> listMaps() async {
  final root = await _rootDirectory();
  await root.create(recursive: true);
  final items = <MapLibraryItem>[];

  await for (final entity in root.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final folderName = p.basename(entity.path);
    if (folderName.startsWith('.')) continue;

    try {
      if (!MapMeta.isValidId(folderName)) {
        throw FormatException('Invalid map folder ID: $folderName');
      }
      final meta = await readMeta(folderName);
      if (meta.id != folderName) {
        throw FormatException(
          'Metadata ID "${meta.id}" does not match folder "$folderName"',
        );
      }
      items.add(MapLibraryItem.valid(meta));
    } catch (error) {
      items.add(MapLibraryItem.issue(folderId: folderName, error: error));
    }
  }

  items.sort((a, b) => a.folderId.compareTo(b.folderId));
  return List.unmodifiable(items);
}

Future<MapMeta> readMeta(String id) async {
  final mapPath = await _validatedMapPath(id);
  final folder = Directory(mapPath);
  if (!await folder.exists()) {
    throw StateError('Map folder not found: $id');
  }

  final file = File(p.join(mapPath, 'meta.json'));
  if (!await file.exists()) {
    throw StateError('meta.json not found for map: $id');
  }

  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('meta.json must contain a JSON object');
  }
  final meta = MapMeta.fromJson(decoded);
  if (meta.id != id) {
    throw FormatException('Metadata ID "${meta.id}" does not match "$id"');
  }
  return meta;
}

Future<void> writeMeta(MapMeta meta) async {
  final mapPath = await _validatedMapPath(meta.id);
  final folder = Directory(mapPath);
  if (!await folder.exists()) {
    throw StateError(
      'Map folder does not exist. MapLibraryStore does not create map folders.',
    );
  }

  final target = File(p.join(mapPath, 'meta.json'));
  final temporary = File(p.join(mapPath, 'meta.json.tmp'));
  await temporary.writeAsString(jsonEncode(meta.toJson()), flush: true);

  // Replace metadata atomically where the platform filesystem supports rename.
  if (await target.exists()) {
    await target.delete();
  }
  await temporary.rename(target.path);
}
