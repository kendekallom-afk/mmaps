import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'stored_map_file.dart';

Future<Directory> _libraryDirectory() async {
  final supportDirectory = await getApplicationSupportDirectory();
  final directory = Directory(
    '${supportDirectory.path}${Platform.pathSeparator}maps_library',
  );
  await directory.create(recursive: true);
  return directory;
}

Future<List<StoredMapFile>> loadStoredMapFiles() async {
  final directory = await _libraryDirectory();
  final files = <StoredMapFile>[];
  await for (final entity in directory.list()) {
    if (entity is! File) continue;
    final storedName = entity.path.split(Platform.pathSeparator).last;
    final separator = storedName.indexOf('--');
    if (separator <= 0) continue;
    final originalName = storedName.substring(separator + 2);
    final extension = originalName.split('.').last.toLowerCase();
    if (extension != 'kml' && extension != 'kmz') continue;
    final id = storedName.substring(0, separator);
    files.add(
      StoredMapFile(
        id: id,
        name: originalName,
        bytes: await entity.readAsBytes(),
      ),
    );
  }
  files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return files;
}

Future<void> saveStoredMapFile(StoredMapFile file) async {
  final directory = await _libraryDirectory();
  final safeName = file.name.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_');
  final storedFile = File(
    '${directory.path}${Platform.pathSeparator}${file.id}--$safeName',
  );
  await storedFile.writeAsBytes(file.bytes, flush: true);
}

Future<void> removeStoredMapFile(String id) async {
  final directory = await _libraryDirectory();
  await for (final entity in directory.list()) {
    if (entity is File &&
        entity.path.split(Platform.pathSeparator).last.startsWith('$id--')) {
      await entity.delete();
    }
  }
  final activeIds = await loadStoredActiveIds();
  activeIds.remove(id);
  await saveStoredActiveIds(activeIds);
}

Future<Set<String>> loadStoredActiveIds() async {
  final directory = await _libraryDirectory();
  final file = File(
    '${directory.path}${Platform.pathSeparator}active_layers.json',
  );
  if (!await file.exists()) return {};
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! List) {
    throw const FormatException('Data Active Layers tidak valid.');
  }
  return decoded.whereType<String>().toSet();
}

Future<void> saveStoredActiveIds(Set<String> ids) async {
  final directory = await _libraryDirectory();
  final file = File(
    '${directory.path}${Platform.pathSeparator}active_layers.json',
  );
  await file.writeAsString(jsonEncode(ids.toList()), flush: true);
}
