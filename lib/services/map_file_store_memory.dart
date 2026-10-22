import 'stored_map_file.dart';

final Map<String, StoredMapFile> _files = {};
Set<String> _activeIds = {};

Future<List<StoredMapFile>> loadStoredMapFiles() async =>
    List.unmodifiable(_files.values);

Future<void> saveStoredMapFile(StoredMapFile file) async {
  _files[file.id] = file;
}

Future<void> removeStoredMapFile(String id) async {
  _files.remove(id);
  _activeIds.remove(id);
}

Future<Set<String>> loadStoredActiveIds() async => Set.of(_activeIds);

Future<void> saveStoredActiveIds(Set<String> ids) async {
  _activeIds = Set.of(ids);
}
