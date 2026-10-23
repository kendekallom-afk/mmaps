import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

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

/// Mengembalikan daftar metadata file (id, name, size) tanpa membaca isi bytes file
Future<List<StoredMapFileInfo>> listStoredMapFiles() async {
  final directory = await _libraryDirectory();
  final files = <StoredMapFileInfo>[];
  await for (final entity in directory.list()) {
    if (entity is! File) continue;
    final storedName = entity.path.split(Platform.pathSeparator).last;
    final separator = storedName.indexOf('--');
    if (separator <= 0) continue;
    final originalName = storedName.substring(separator + 2);
    final extension = originalName.split('.').last.toLowerCase();
    if (extension != 'kml' && extension != 'kmz') continue;
    final id = storedName.substring(0, separator);
    final stat = await entity.stat();
    files.add(
      StoredMapFileInfo(
        id: id,
        name: originalName,
        size: stat.size,
      ),
    );
  }
  files.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return files;
}

/// Membaca bytes isi file berdasarkan [id] secara on-demand / lazy
Future<Uint8List> readStoredMapFile(String id) async {
  final directory = await _libraryDirectory();
  await for (final entity in directory.list()) {
    if (entity is! File) continue;
    final fileName = entity.path.split(Platform.pathSeparator).last;
    if (fileName.startsWith('$id--')) {
      return await entity.readAsBytes();
    }
  }
  throw StateError('File peta dengan ID $id tidak ditemukan di penyimpanan.');
}

/// Backward compatibility: memuat semua file beserta bytes
Future<List<StoredMapFile>> loadStoredMapFiles() async {
  final list = await listStoredMapFiles();
  final files = <StoredMapFile>[];
  for (final info in list) {
    try {
      final bytes = await readStoredMapFile(info.id);
      files.add(StoredMapFile(id: info.id, name: info.name, bytes: bytes));
    } catch (_) {
      // Abaikan jika file tidak dapat dibaca
    }
  }
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
