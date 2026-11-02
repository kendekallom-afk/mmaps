/// Persistent active-map IDs and valid IDs whose folders are missing.
class MapLibraryActiveIndex {
  final List<String> mapIds;
  final List<String> orphanIds;

  MapLibraryActiveIndex({
    required List<String> mapIds,
    required List<String> orphanIds,
  })  : mapIds = List.unmodifiable(mapIds),
        orphanIds = List.unmodifiable(orphanIds);
}
