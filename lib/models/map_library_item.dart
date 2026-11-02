import 'map_meta.dart';

/// One entry in the folder-based map library.
///
/// A failed metadata read is represented as an issue so one damaged folder
/// does not prevent the rest of the library from being listed.
class MapLibraryItem {
  final String folderId;
  final MapMeta? meta;
  final Object? error;

  const MapLibraryItem._({
    required this.folderId,
    required this.meta,
    required this.error,
  });

  factory MapLibraryItem.valid(MapMeta meta) => MapLibraryItem._(
        folderId: meta.id,
        meta: meta,
        error: null,
      );

  factory MapLibraryItem.issue({
    required String folderId,
    required Object error,
  }) =>
      MapLibraryItem._(
        folderId: folderId,
        meta: null,
        error: error,
      );

  bool get isValid => meta != null;
}
