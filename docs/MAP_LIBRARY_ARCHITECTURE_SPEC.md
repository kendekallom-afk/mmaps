# mMaps Map Library & Import Architecture Specification

- **Status:** Frozen design specification (pre-implementation)
- **Version:** 1.0
- **Scope:** Map library storage, KML/KMZ import, MapLibre layer lifecycle, legacy migration
- **Target:** Android and iOS with persistent storage; Web with memory-only behavior
- **Implementation rule:** This document is the contract for incremental implementation. Do not implement multiple phases at once.

## 1. Goals and non-goals

### Goals
- Store each imported map as an independently managed folder.
- Preserve the original KML/KMZ source file.
- Parse once at import/migration time and reuse generated GeoJSON during activation.
- Keep library listing lightweight: read metadata only.
- Improve import and activation performance on low-memory devices, especially Samsung XCover4 / Android 9 / 2 GB RAM.
- Manage MapLibre sources and layers deterministically.
- Preserve every source coordinate and geometry vertex exactly. No simplification, thinning, rounding, or geometry alteration unless separately approved.
- Make imports, migration, and deletion recoverable after interruption.

### Non-goals
- No basemap redesign.
- No geometry simplification or topology repair.
- No automatic migration during normal startup.
- No runtime probing of file-URI support on every activation.
- No replacement of existing map folders during normal import.

## 2. Storage layout

Persistent IO backend:

```text
maps_library/
├── active_layers.json
├── .tmp/
├── .deleting/
└── <mapId>/
    ├── original.kml OR original.kmz
    ├── polygons.geojson
    ├── lines.geojson
    ├── points.geojson
    ├── layer_style.json
    └── meta.json
```

Rules:
- Keep the original source extension truthful: KML bytes use `original.kml`; KMZ bytes use `original.kmz`.
- Always write all three GeoJSON files, including empty FeatureCollections.
- `.tmp` and `.deleting` are internal directories and must never appear as library maps.
- `active_layers.json` is the sole persistent source of active-map IDs. Do not duplicate active state in `meta.json`.
- Library listing reads only each map's `meta.json`; it must not read GeoJSON or original source bytes.
- A root scan failure is an error, not a successful empty library.
- Malformed or missing metadata is reported as a folder issue; do not silently delete it.

## 3. Map ID validation and path safety

Map IDs must match:

```regex
^[a-z0-9_][a-z0-9_-]{0,63}$
```

Additional rules:
- Lowercase ASCII only; reject uppercase rather than normalizing it.
- Maximum length 64 characters.
- No leading dot or hyphen.
- No slash, backslash, drive/volume separator, control character, or path traversal.
- Reject reserved root names, at minimum: `.tmp`, `.deleting`, and `active_layers`.
- Display names are not IDs and must never be used as filesystem paths.
- If the MapLibre separator fallback `__` is selected, additionally reject IDs containing consecutive underscores (`__`).
- Validate IDs on every read, write, activation, deactivation, migration, and deletion operation.
- IO backend must normalize/resolve the resulting path and verify it remains inside the canonical library root. String concatenation alone is insufficient.

## 4. Metadata contract

`meta.json` is the identity and validation record for a map. It must include at least:
- `id`: must equal the containing folder name.
- `formatVersion`: storage schema version.
- Display name and source information.
- `originalExtension`: `kml` or `kmz`.
- Import timestamp.
- `featureCounts`: counts for `polygons`, `lines`, and `points`.
- `bounds`: exactly `[minLon, minLat, maxLon, maxLat]`.

Validation:
- Reject malformed metadata as a reported issue.
- A valid ID in metadata must match the folder name.
- A future unsupported `formatVersion` must be surfaced distinctly from corrupt metadata.
- Validate generated GeoJSON and compare its feature counts with metadata before committing an import.

## 5. Class responsibilities

| Component | Responsibility |
|---|---|
| `MapMeta` | Metadata model, serialization, validation, version checks |
| `MapLibraryStore` | New folder-based storage; list metadata, read source/GeoJSON/style, active index, safe deletion |
| `LegacyMapFileStore` | Old single-file storage only |
| `MapImporter` | Source validation, parsing, GeoJSON/style/meta generation, staging, validation, atomic commit, progress events |
| `MapLayerManager` | MapLibre source/layer IDs, source and layer lifecycle, ordering, visibility, opacity, style reset recovery |
| `MapHomePage` | UI and orchestration only; migrate incrementally |

The old `MapFileStore` facade may temporarily remain as a legacy adapter. During transition, `MapFileStore.remove(id)` must map only to legacy-file deletion. It must never fall through to deleting a new folder.

## 6. Import and parsing

### Input API
- Native Android/iOS `MapImporter.importMap` receives a source file path, not a `Uint8List`.
- Web uses a memory-only backend. Because browser file selection does not provide a normal persistent filesystem path, Web import must use a platform-specific in-memory source adapter rather than pretending a native path exists. Keep the parser core reusable; document this platform boundary explicitly.

### Parsing requirements
- Validate source extension and file content.
- KMZ: perform ZIP preflight before extraction/parsing.
- Parse KML styles and StyleMap before Placemark feature generation (two-pass approach).
- Parse Placemarks in a streaming/per-Placemark manner where practical to limit peak memory.
- Preserve style references, ExtendedData, descriptions, and relevant attributes in GeoJSON properties.
- Handle supported GroundOverlay content explicitly; unsupported cases must produce a clear import issue rather than silent loss.
- Preserve all coordinates and vertices exactly. Never simplify geometry.
- Run CPU- and memory-intensive parsing off the UI isolate where supported.

### Generated files
- `polygons.geojson`
- `lines.geojson`
- `points.geojson`
- `layer_style.json` generated by `MapImporter`, not supplied by the caller.
- `meta.json`

All three GeoJSON files are written even when empty. Empty files contain valid empty FeatureCollections.

## 7. Progress and failure events

Importer exposes a progress callback or stream with real stages:
1. source validation
2. ZIP preflight/reading (KMZ)
3. KML and style parsing
4. feature generation
5. GeoJSON writes
6. `layer_style.json` write
7. metadata write
8. output validation
9. atomic commit
10. complete

Progress must also report failure:
- stage where failure occurred
- failed status
- user-readable message
- technical error details when available

Example event:

```json
{
  "stage": "kml_parsing",
  "status": "failed",
  "message": "Gagal pada tahap parsing KML"
}
```

UI must not display only a generic import-failed message when a specific stage is known.

## 8. Atomic import and staging cleanup

- Stage each import under `.tmp/<mapId>-<nonce>/` on the same filesystem as the final library folder.
- Track active staging nonce IDs in memory only; the app is single-process.
- No on-disk lease or marker file is required.
- At startup, no import is active yet, so all directories under `.tmp/` are leftovers and may be cleaned.
- During runtime, cleanup may remove only staging directories whose nonce is not active and which are older than the configured age threshold.
- Validate all expected outputs, metadata, GeoJSON syntax, and feature counts before commit.
- Rename the staging directory to the final `maps_library/<mapId>/` only if the final destination does not exist.
- Never replace an existing final folder automatically.
- An ID collision is a typed conflict error.
- If the process stops before commit, staging is ignored by library listing and cleaned at next startup.

## 9. Active index

`active_layers.json`:
- Stores IDs only.
- Is the sole persistent active-state source.
- Writes atomically through a sibling temporary file, flush, then replace.
- Valid orphan IDs are reported; do not silently delete them.
- A malformed/corrupt index is reported. Do not overwrite it with an empty list silently; recovery must be explicit.

## 10. Deletion and interrupted deletion recovery

Deletion of a new map folder is exclusively `MapLibraryStore.removeMap(id)`. Legacy deletion is exclusively `LegacyMapFileStore.removeLegacyFile(id)`.

New-map deletion flow:
1. Detach that map's MapLibre layers and sources.
2. Remove the ID from the active index and persist the index atomically.
3. Rename `maps_library/<id>` to `maps_library/.deleting/<id>-<nonce>`.
4. Recursively delete the renamed directory.
5. Report errors; never report success if rename or deletion failed.

Nonce avoids collisions with remnants from previous interrupted deletions. At startup, clean abandoned entries under `.deleting/`. These entries are never listed as maps.

If rename fails, preserve the original folder and report failure. If recursive deletion fails after rename, leave the uniquely named `.deleting` entry for startup cleanup/retry.

## 11. MapLibre source and layer management

### ID builder
- All source and layer IDs must come from one function/class, e.g. `MapLibreIdBuilder`.
- Primary candidate format uses `kmz::<mapId>::...`.
- Test `::` on actual Android and iOS devices before final adoption.
- Fallback candidates: `.` or `__`.
- If `__` is selected, enforce the additional map-ID rule prohibiting `__` inside map IDs.
- A delimiter change must require changing only the central ID builder, not scattered call sites.

### Geometry grouping and order
Global order is by geometry type:
1. all polygons at the bottom
2. all lines above polygons
3. all points above lines
4. puck and waypoint layers above map geometry

Within each geometry group, newer maps appear above older maps. Polygon fill must remain below its outline. The manager must calculate insertion order deterministically; do not assume that adding layers in sequence or using an anchor automatically produces the intended order.

Create three stable style slots/anchors (polygon, line, point) once during style initialization, below puck and waypoint layers. The exact MapLibre-compatible anchor implementation must be validated against the current plugin/style API before implementation. Do not invent invisible anchor layers that require unsupported sources. Keep the slots fixed across map activation/deactivation.

### Sources and geometry
- One source per map and geometry type.
- Polygon: source + fill + outline.
- Line: source + line layer.
- Point: source + circle layer.
- Check feature counts before creating a source/layer.
- If feature count is zero, do not create an empty source or layer.
- If geometry is removed/becomes empty, remove its layers first, then its source.
- Do not update a source with an empty FeatureCollection merely to keep it alive.
- Do not re-set unchanged GeoJSON data.

### Removal
For deactivation, deletion, and style/basemap replacement:
- Await each `removeLayer` operation first.
- Only after layer removal, await `removeSource`.
- Isolate errors per map/geometry so one failed removal does not stop cleanup of other maps.
- Log/report failed IDs and operations for diagnosis.

### Styling
- Use MapLibre paint properties for opacity, fill, outline, and line styling.
- Changing opacity or outline must not require rewriting GeoJSON.
- Debounce rapid style updates.
- Persist user style configuration in `layer_style.json`.
- Reattach sources/layers after style reset using the manager's known state.

## 12. GeoJSON file URI optimization

- `geoJsonFileUri(id, kind)` is optional and available only on persistent IO storage; memory backend returns null.
- Inline `readGeoJson` remains the fallback.
- URI support status is a code constant per platform, not a runtime trial on every activation.
- Document beside each platform constant: test date, `maplibre_gl` version, device/OS, and result.
- Test file URI support on actual Android and iOS devices. Do not assume support from API shape alone.
- If reliable native readiness/error signaling is unavailable, mark URI unsupported for that platform and use inline data.
- URI is an optimization only; storage and import architecture must not depend on it.

## 13. Platform behavior

- Android/iOS: persistent IO library and full folder-based storage.
- Web: memory-only library backend; no claim of persistence across browser/app restarts.
- Keep platform-specific filesystem access behind conditional imports/adapters.
- Keep parser logic shared where possible, but source input adapters may differ by platform.

## 14. Legacy migration

- Normal startup/listing does not auto-migrate.
- Normal import refuses an ID collision if a new folder already exists, even if contents appear identical.
- `migrateLegacyMap()` is idempotent:
  - If a validated new folder exists and matches the same source, return `alreadyMigrated` without rewriting.
  - If the ID exists but source differs, return conflict; do not delete the legacy file.
  - On successful migration, preserve the legacy source file.
  - Legacy deletion is a separate explicit operation after new-folder validation and commit.
- Migration retries must not lose the original source.
- `LegacyMapFileStore.removeLegacyFile(id)` removes only the legacy file.
- `MapLibraryStore.removeMap(id)` removes only the new folder.
- The temporary `MapFileStore.remove(id)` adapter maps only to legacy deletion; never fall through to new storage.

## 15. Library UI and startup

Startup sequence:
1. Initialize library root.
2. Clean all stale `.tmp` entries (single-process startup assumption).
3. Clean abandoned `.deleting` entries.
4. Read and validate `active_layers.json`; surface corruption/orphan IDs.
5. Scan map folders and read only `meta.json`.
6. Present valid maps and folder issues separately.
7. Load GeoJSON only for maps that need to be activated/restored in MapLibre.

Library UI:
- Show valid maps and actionable issues.
- Do not read original source or GeoJSON bytes just to populate the list.
- Active state comes from `active_layers.json` only.
- Offer explicit recovery/removal for malformed folders; do not delete them automatically.

## 16. MapHomePage integration constraints

- `MapHomePage` remains UI/orchestration, not the storage/parser/layer implementation.
- Migrate incrementally; preserve existing GPS lifecycle, puck, waypoint behavior, prewarming, and synchronization safeguards unless a separately reviewed change is approved.
- Preserve the existing serialized source-update queue during transition where needed.
- Guard MapLibre operations against style-not-ready state.
- Do not block the UI isolate with large parsing/serialization work.
- Avoid redundant empty source creation and redundant source updates.
- Report per-map errors without preventing unrelated maps from loading or being removed.

## 17. Implementation sequence

Complete one phase, test it, and review before proceeding:

1. Add this frozen specification to the repository.
2. Implement `MapMeta` model and unit tests only.
3. Implement persistent `MapLibraryStore` IO backend.
4. Implement Web memory backend.
5. Add tests for ID/path safety, staging cleanup, conflicts, deletion, active index, and corrupt folders.
6. Implement `MapImporter` progress events and atomic import.
7. Implement `MapLayerManager`: central ID builder, anchors/order, source/layer creation/removal.
8. Integrate `MapHomePage` incrementally.
9. Implement explicit legacy migration.
10. Benchmark and validate on XCover4 and other target devices.

Do not start the next phase until the current phase's tests pass and its behavior has been reviewed.

## 18. Required device/platform validation

Before relying on optimizations, record:
- MapLibre source/layer ID delimiter acceptance on Android and iOS.
- File-URI GeoJSON source support per platform.
- Anchor/slot behavior and actual rendered order.
- Removal ordering and behavior under partial failures.
- Import and activation time, peak memory if measurable, and behavior with multiple large KMZ maps.

At minimum, test the target Android 9 XCover4 and a modern Android device. iOS behavior must be tested on a real iOS device before being marked supported.

## 19. Invariants that must never be broken

- Original source is retained unless explicitly removed by a separate user-approved policy.
- Geometry coordinates and vertex sequences are preserved exactly.
- Existing final map folders are never overwritten by normal import.
- Library listing reads metadata only.
- Active state has one persistent source of truth.
- Legacy and new storage deletion paths never overlap.
- MapLibre IDs are generated centrally.
- Layers are removed before sources.
- Empty geometry does not create empty MapLibre sources/layers.
- Unverified URI support is never assumed.
- Each implementation phase is small, tested, and reviewed before the next.
