import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../models/map_library_item.dart';
import '../models/map_library_active_index.dart';
import '../models/map_meta.dart';


/// Installs a fully-written temporary file while preserving the previous
/// target until the new file has been moved into place. The backup/restore
/// sequence also supports platforms where rename cannot replace an existing
/// file (notably Windows).
Future<void> _installTemporaryFile(File temporary, File target) async {
  final backup = File(
    '${target.path}.backup-${DateTime.now().microsecondsSinceEpoch}',
  );
  var movedOriginal = false;
  try {
    if (await target.exists()) {
      await target.rename(backup.path);
      movedOriginal = true;
    }
    await temporary.rename(target.path);
    if (movedOriginal && await backup.exists()) {
      await backup.delete();
    }
  } catch (_) {
    if (movedOriginal && await backup.exists() && !await target.exists()) {
      await backup.rename(target.path);
    }
    rethrow;
  } finally {
    if (await temporary.exists()) {
      await temporary.delete();
    }
  }
}

/// Rejects symbolic links at known file paths inside a map folder.
/// Map-library files are expected to be regular files, not redirects to paths
/// elsewhere on the device.
Future<void> _rejectSymbolicLink(String path) async {
  final type = await FileSystemEntity.type(path, followLinks: false);
  if (type == FileSystemEntityType.link) {
    throw FileSystemException('Symbolic links are not allowed in map folders', path);
  }
}

Future<Directory> _rootDirectory() async {
  final support = await getApplicationSupportDirectory();
  return Directory(p.join(support.path, 'maps_library'));
}

/// Recovers interrupted single-file replacements before normal library reads.
/// If the target exists, installation reached its commit point and backups are
/// stale. If it is absent, restore the newest backup before removing leftovers.
Future<void> _recoverBackupFiles(Directory folder) async {
  if (!await folder.exists()) return;
  final backups = <String, List<File>>{};

  await for (final entity in folder.list(followLinks: false)) {
    if (entity is! File) continue;
    final name = p.basename(entity.path);
    final marker = name.lastIndexOf('.backup-');
    if (marker <= 0) continue;
    final suffix = name.substring(marker + '.backup-'.length);
    if (int.tryParse(suffix) == null) continue;
    await _rejectSymbolicLink(entity.path);
    backups.putIfAbsent(name.substring(0, marker), () => <File>[]).add(entity);
  }

  for (final entry in backups.entries) {
    final target = File(p.join(folder.path, entry.key));
    await _rejectSymbolicLink(target.path);
    final candidates = entry.value
      ..sort((a, b) {
        final aStamp = int.tryParse(a.path.split('.backup-').last) ?? 0;
        final bStamp = int.tryParse(b.path.split('.backup-').last) ?? 0;
        return bStamp.compareTo(aStamp);
      });

    if (!await target.exists()) {
      // Restore one known previous version. Never promote an uncommitted .tmp.
      await candidates.first.rename(target.path);
      candidates.removeAt(0);
    }
    for (final backup in candidates) {
      if (await backup.exists()) await backup.delete();
    }
  }

  // A .tmp sibling is never authoritative; the target or backup is safer.
  await for (final entity in folder.list(followLinks: false)) {
    if (entity is! File) continue;
    if (p.basename(entity.path).endsWith('.tmp')) {
      await _rejectSymbolicLink(entity.path);
      await entity.delete();
    }
  }
}

/// Removes abandoned contents of an internal directory without following links.
Future<void> _emptyInternalDirectory(Directory directory) async {
  if (await FileSystemEntity.type(directory.path, followLinks: false) ==
      FileSystemEntityType.link) {
    throw FileSystemException('Internal library directory cannot be a link',
        directory.path);
  }
  await directory.create(recursive: true);
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is Link) {
      await entity.delete();
    } else if (entity is Directory) {
      await entity.delete(recursive: true);
    } else if (entity is File) {
      await entity.delete();
    }
  }
}

Future<void> initializeLibrary() async {
  final root = await _rootDirectory();
  await root.create(recursive: true);

  // Recover the active index and per-map files before deleting temporary data.
  await _recoverBackupFiles(root);
  await for (final entity in root.list(followLinks: false)) {
    if (entity is Directory && !p.basename(entity.path).startsWith('.')) {
      await _recoverBackupFiles(entity);
    }
  }

  await _emptyInternalDirectory(Directory(p.join(root.path, '.tmp')));
  await _emptyInternalDirectory(Directory(p.join(root.path, '.deleting')));
}

Future<String> _validatedMapPath(String id) async {
  if (!MapMeta.isValidId(id)) {
    throw FormatException('Invalid map ID: $id');
  }

  final root = await _rootDirectory();
  await root.create(recursive: true);
  final canonicalRoot = await root.resolveSymbolicLinks();
  final candidate = Directory(p.join(canonicalRoot, id));
  final candidatePath = p.normalize(candidate.absolute.path);
  final expectedPrefix = p.normalize(canonicalRoot + Platform.pathSeparator);

  // An existing map folder may itself be a symbolic link. Resolve it before
  // accessing metadata so a link cannot redirect reads/writes outside root.
  final entityType = await FileSystemEntity.type(
    candidatePath,
    followLinks: false,
  );
  final resolved = entityType == FileSystemEntityType.link
      ? await candidate.resolveSymbolicLinks()
      : candidatePath;
  final normalizedResolved = p.normalize(resolved);
  final comparableResolved =
      Platform.isWindows ? normalizedResolved.toLowerCase() : normalizedResolved;
  final comparableRoot =
      Platform.isWindows ? expectedPrefix.toLowerCase() : expectedPrefix;

  if (!comparableResolved.startsWith(comparableRoot)) {
    throw FormatException('Map path escapes library root: $id');
  }
  return normalizedResolved;
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

  final filePath = p.join(mapPath, 'meta.json');
  await _rejectSymbolicLink(filePath);
  final file = File(filePath);
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

  final targetPath = p.join(mapPath, 'meta.json');
  final temporaryPath = p.join(mapPath, 'meta.json.tmp');
  await _rejectSymbolicLink(targetPath);
  await _rejectSymbolicLink(temporaryPath);
  final target = File(targetPath);
  final temporary = File(temporaryPath);
  final backup = File(
    p.join(mapPath, 'meta.json.backup-${DateTime.now().microsecondsSinceEpoch}'),
  );

  // Write and flush the complete new file before touching the current one.
  await temporary.writeAsString(jsonEncode(meta.toJson()), flush: true);

  var movedOriginal = false;
  try {
    if (await target.exists()) {
      await target.rename(backup.path);
      movedOriginal = true;
    }

    await temporary.rename(target.path);

    // The new metadata is in place; the old copy is no longer needed.
    if (movedOriginal && await backup.exists()) {
      await backup.delete();
    }
  } catch (_) {
    // If installation of the new file fails, restore the old metadata.
    if (movedOriginal &&
        await backup.exists() &&
        !await target.exists()) {
      await backup.rename(target.path);
    }
    rethrow;
  } finally {
    if (await temporary.exists()) {
      await temporary.delete();
    }
  }
}

Future<List<int>> readOriginalSource(String id) async {
  final mapPath = await _validatedMapPath(id);
  final meta = await readMeta(id);
  final extension = meta.originalExtension.toLowerCase();
  if (extension != 'kml' && extension != 'kmz') {
    throw FormatException('Unsupported original source extension: $extension');
  }
  final filePath = p.join(mapPath, 'original.$extension');
  await _rejectSymbolicLink(filePath);
  final file = File(filePath);
  if (!await file.exists()) {
    throw StateError('Original source not found for map: $id');
  }
  return file.readAsBytes();
}

Future<void> writeOriginalSource(String id, List<int> bytes) async {
  final mapPath = await _validatedMapPath(id);
  final folder = Directory(mapPath);
  if (!await folder.exists()) {
    throw StateError('Map folder does not exist: $id');
  }
  final meta = await readMeta(id);
  final extension = meta.originalExtension.toLowerCase();
  if (extension != 'kml' && extension != 'kmz') {
    throw FormatException('Unsupported original source extension: $extension');
  }

  final targetPath = p.join(mapPath, 'original.$extension');
  final temporaryPath = p.join(mapPath, 'original.$extension.tmp');
  await _rejectSymbolicLink(targetPath);
  await _rejectSymbolicLink(temporaryPath);
  final target = File(targetPath);
  final temporary = File(temporaryPath);
  await temporary.writeAsBytes(bytes, flush: true);
  await _installTemporaryFile(temporary, target);
}


String _geoJsonFileName(String geometry) {
  switch (geometry) {
    case 'polygons':
    case 'lines':
    case 'points':
      return '$geometry.geojson';
    default:
      throw FormatException(
        'Unsupported geometry type: $geometry. Use polygons, lines, or points.',
      );
  }
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
  final mapPath = await _validatedMapPath(id);
  final fileName = _geoJsonFileName(geometry);
  if (!await Directory(mapPath).exists()) {
    throw StateError('Map folder not found: $id');
  }
  final filePath = p.join(mapPath, fileName);
  await _rejectSymbolicLink(filePath);
  final file = File(filePath);
  if (!await file.exists()) {
    throw StateError('$fileName not found for map: $id');
  }
  final content = await file.readAsString();
  _validateFeatureCollection(content);
  return content;
}

Future<void> writeGeoJson(String id, String geometry, String content) async {
  final mapPath = await _validatedMapPath(id);
  final fileName = _geoJsonFileName(geometry);
  if (!await Directory(mapPath).exists()) {
    throw StateError('Map folder does not exist: $id');
  }
  _validateFeatureCollection(content);
  final targetPath = p.join(mapPath, fileName);
  final temporaryPath = p.join(mapPath, '$fileName.tmp');
  await _rejectSymbolicLink(targetPath);
  await _rejectSymbolicLink(temporaryPath);
  final target = File(targetPath);
  final temporary = File(temporaryPath);
  await temporary.writeAsString(content, flush: true);
  await _installTemporaryFile(temporary, target);
}


void _validateLayerStyle(String content) {
  final decoded = jsonDecode(content);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('layer_style.json must contain a JSON object');
  }
}

Future<String> readLayerStyle(String id) async {
  final mapPath = await _validatedMapPath(id);
  if (!await Directory(mapPath).exists()) {
    throw StateError('Map folder not found: $id');
  }
  final filePath = p.join(mapPath, 'layer_style.json');
  await _rejectSymbolicLink(filePath);
  final file = File(filePath);
  if (!await file.exists()) {
    throw StateError('layer_style.json not found for map: $id');
  }
  final content = await file.readAsString();
  _validateLayerStyle(content);
  return content;
}

Future<void> writeLayerStyle(String id, String content) async {
  final mapPath = await _validatedMapPath(id);
  if (!await Directory(mapPath).exists()) {
    throw StateError('Map folder does not exist: $id');
  }
  _validateLayerStyle(content);
  final targetPath = p.join(mapPath, 'layer_style.json');
  final temporaryPath = p.join(mapPath, 'layer_style.json.tmp');
  await _rejectSymbolicLink(targetPath);
  await _rejectSymbolicLink(temporaryPath);
  final target = File(targetPath);
  final temporary = File(temporaryPath);
  await temporary.writeAsString(content, flush: true);
  await _installTemporaryFile(temporary, target);
}

Future<MapLibraryActiveIndex> readActiveMapIndex() async {
  final root = await _rootDirectory();
  await root.create(recursive: true);
  final file = File(p.join(root.path, 'active_layers.json'));
  if (!await file.exists()) {
    return MapLibraryActiveIndex(mapIds: const [], orphanIds: const []);
  }

  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! List) {
    throw const FormatException('active_layers.json must contain a JSON array');
  }
  final ids = <String>[];
  final seen = <String>{};
  for (final value in decoded) {
    if (value is! String || !MapMeta.isValidId(value)) {
      throw const FormatException('active_layers.json contains an invalid map ID');
    }
    if (!seen.add(value)) {
      throw FormatException('active_layers.json contains duplicate ID: $value');
    }
    ids.add(value);
  }

  final orphans = <String>[];
  for (final id in ids) {
    final folder = Directory(p.join(root.path, id));
    if (!await folder.exists()) orphans.add(id);
  }
  return MapLibraryActiveIndex(mapIds: ids, orphanIds: orphans);
}

Future<void> writeActiveMapIds(List<String> ids) async {
  final unique = <String>{};
  for (final id in ids) {
    if (!MapMeta.isValidId(id)) {
      throw FormatException('Invalid active map ID: $id');
    }
    if (!unique.add(id)) {
      throw FormatException('Duplicate active map ID: $id');
    }
  }

  final root = await _rootDirectory();
  await root.create(recursive: true);
  final target = File(p.join(root.path, 'active_layers.json'));
  final temporary = File(p.join(root.path, 'active_layers.json.tmp'));
  final backup = File(
    p.join(root.path, 'active_layers.json.backup-${DateTime.now().microsecondsSinceEpoch}'),
  );

  // Validate existing content before replacing it. Corruption requires
  // explicit recovery rather than silently resetting the active list.
  if (await target.exists()) {
    await readActiveMapIndex();
  }

  await temporary.writeAsString(jsonEncode(ids), flush: true);
  var movedOriginal = false;
  try {
    if (await target.exists()) {
      await target.rename(backup.path);
      movedOriginal = true;
    }
    await temporary.rename(target.path);
    if (movedOriginal && await backup.exists()) await backup.delete();
  } catch (_) {
    if (movedOriginal && await backup.exists() && !await target.exists()) {
      await backup.rename(target.path);
    }
    rethrow;
  } finally {
    if (await temporary.exists()) await temporary.delete();
  }
}
