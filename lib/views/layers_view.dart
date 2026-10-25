import 'package:flutter/material.dart';

import '../models/basemap.dart';
import '../models/imported_map.dart';

class LayersView extends StatelessWidget {
  final int selectedTab;
  final ValueChanged<int> onTabChanged;
  final List<ImportedMap> maps;
  final List<Basemap> customBasemaps;
  final Basemap? activeBasemap;
  final ValueChanged<Basemap?> onBasemapChanged;
  final Future<void> Function() onAddCustomBasemap;
  final VoidCallback onImportMap;
  final ValueChanged<ImportedMap> onToggleMap;
  final ValueChanged<ImportedMap> onRemoveMap;
  final bool importing;
  final bool loading;
  final Set<String> busyMapIds;

  const LayersView({
    super.key,
    required this.selectedTab,
    required this.onTabChanged,
    required this.maps,
    required this.customBasemaps,
    required this.activeBasemap,
    required this.onBasemapChanged,
    required this.onAddCustomBasemap,
    required this.onImportMap,
    required this.onToggleMap,
    required this.onRemoveMap,
    required this.importing,
    required this.loading,
    this.busyMapIds = const {},
  });

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFFE4E4E4),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
            decoration: const BoxDecoration(
              color: Color(0xFFF4F4F4),
              border: Border(bottom: BorderSide(color: Color(0xFFBDBDBD))),
            ),
            child: const Text(
              'Layers',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Active Layers',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                if (maps.where((map) => map.isActive).isEmpty &&
                    activeBasemap == null)
                  const EmptyLibrary(
                    icon: Icons.layers_clear_outlined,
                    title: 'Belum ada layer aktif',
                    message: 'Pilih peta dari Maps Library untuk ditampilkan.',
                  )
                else
                  ...maps
                      .where((map) => map.isActive)
                      .map(
                        (map) => ActiveMapItem(
                          map: map,
                          onRemove: () => onToggleMap(map),
                        ),
                      ),
                if (activeBasemap case final basemap?)
                  ActiveBasemapItem(
                    basemap: basemap,
                    onRemove: () => onBasemapChanged(null),
                  ),
                const SizedBox(height: 24),
                Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFFD6D6D6),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: const EdgeInsets.all(4),
                  child: Row(
                    children: [
                      LibraryTab(
                        label: 'Maps Library',
                        selected: selectedTab == 0,
                        onTap: () => onTabChanged(0),
                      ),
                      LibraryTab(
                        label: 'Basemap',
                        selected: selectedTab == 1,
                        onTap: () => onTabChanged(1),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
                if (selectedTab == 0)
                  MapsLibrary(
                    maps: maps,
                    onImportMap: onImportMap,
                    onToggleMap: onToggleMap,
                    onRemoveMap: onRemoveMap,
                    importing: importing,
                    loading: loading,
                    busyMapIds: busyMapIds,
                  )
                else
                  BasemapChoices(
                    activeBasemap: activeBasemap,
                    onBasemapChanged: onBasemapChanged,
                    customBasemaps: customBasemaps,
                    onAddCustomBasemap: onAddCustomBasemap,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class MapsLibrary extends StatelessWidget {
  final List<ImportedMap> maps;
  final VoidCallback onImportMap;
  final ValueChanged<ImportedMap> onToggleMap;
  final ValueChanged<ImportedMap> onRemoveMap;
  final bool importing;
  final bool loading;
  final Set<String> busyMapIds;

  const MapsLibrary({
    super.key,
    required this.maps,
    required this.onImportMap,
    required this.onToggleMap,
    required this.onRemoveMap,
    required this.importing,
    required this.loading,
    required this.busyMapIds,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: importing ? null : onImportMap,
          icon: importing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.file_upload_outlined),
          label: Text(importing ? 'Importing...' : 'Import Maps'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF5D839E),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Import file peta .KML atau .KMZ',
          style: TextStyle(color: Colors.black54, fontSize: 12),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 14),
        if (loading)
          const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator()),
          )
        else if (maps.isEmpty)
          const EmptyLibrary(
            icon: Icons.folder_open_outlined,
            title: 'Maps Library kosong',
            message: 'Import file KML atau KMZ untuk mulai menambahkan peta.',
          )
        else
          ...maps.map(
            (map) => LibraryMapItem(
              map: map,
              onToggle: () => onToggleMap(map),
              onRemove: () => onRemoveMap(map),
              busy: busyMapIds.contains(map.id),
            ),
          ),
      ],
    );
  }
}

class ActiveMapItem extends StatelessWidget {
  final ImportedMap map;
  final VoidCallback onRemove;

  const ActiveMapItem({super.key, required this.map, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8E0A4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.layers, color: Color(0xFF5D839E), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              map.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13),
            ),
          ),
          IconButton(
            onPressed: onRemove,
            tooltip: 'Keluarkan ${map.name} dari Active Layers',
            icon: const Icon(Icons.remove_circle_outline),
            color: Colors.black54,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class ActiveBasemapItem extends StatelessWidget {
  final Basemap basemap;
  final VoidCallback onRemove;

  const ActiveBasemapItem({
    super.key,
    required this.basemap,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFDCE8EF),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.map_outlined, color: Color(0xFF5D839E), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(basemap.label, style: const TextStyle(fontSize: 13)),
          ),
          IconButton(
            onPressed: onRemove,
            tooltip: 'Keluarkan ${basemap.label} dari Active Layers',
            icon: const Icon(Icons.remove_circle_outline),
            color: Colors.black54,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class LibraryMapItem extends StatelessWidget {
  final ImportedMap map;
  final VoidCallback onToggle;
  final VoidCallback onRemove;
  final bool busy;

  const LibraryMapItem({
    super.key,
    required this.map,
    required this.onToggle,
    required this.onRemove,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final featureCount =
        map.points.length +
        map.lines.length +
        map.polygons.length +
        map.overlays.length;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
      decoration: BoxDecoration(
        color: map.isActive ? const Color(0xFFF8E0A4) : Colors.white,
        borderRadius: BorderRadius.circular(6),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 3, offset: Offset(0, 1)),
        ],
      ),
      child: Row(
        children: [
          const Icon(Icons.map_outlined, color: Color(0xFF5D839E), size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  map.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF333333),
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '${map.fileName} · $featureCount fitur',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.black54, fontSize: 11),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: busy ? null : onToggle,
            child: busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(map.isActive ? 'Aktif' : 'Tambah'),
          ),
          IconButton(
            onPressed: onRemove,
            tooltip: 'Hapus ${map.name}',
            icon: const Icon(Icons.delete_outline, size: 20),
            color: Colors.black54,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class LibraryTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const LibraryTab({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Material(
        color: selected ? Colors.white : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 11),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  color: selected ? Colors.black87 : Colors.black54,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class EmptyLibrary extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;

  const EmptyLibrary({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 30),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: const Color(0xFFCCCCCC)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Icon(icon, size: 38, color: Colors.black38),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.black54, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class BasemapChoices extends StatelessWidget {
  final Basemap? activeBasemap;
  final ValueChanged<Basemap?> onBasemapChanged;
  final List<Basemap> customBasemaps;
  final Future<void> Function() onAddCustomBasemap;

  const BasemapChoices({
    super.key,
    required this.activeBasemap,
    required this.onBasemapChanged,
    required this.customBasemaps,
    required this.onAddCustomBasemap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: onAddCustomBasemap,
          icon: const Icon(Icons.add),
          label: const Text('Add Custom XYZ Tiles'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF5D839E),
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
          ),
        ),
        const SizedBox(height: 14),
        BasemapCard(
          name: Basemap.openFreeMap.label,
          detail: 'Peta jalan',
          icon: Icons.map_outlined,
          selected: activeBasemap == Basemap.openFreeMap,
          onTap: () => onBasemapChanged(
            activeBasemap == Basemap.openFreeMap ? null : Basemap.openFreeMap,
          ),
        ),
        for (final basemap in customBasemaps) ...[
          const SizedBox(height: 10),
          BasemapCard(
            name: basemap.label,
            detail: basemap.detail,
            icon: Icons.grid_on_outlined,
            selected: activeBasemap == basemap,
            onTap: () =>
                onBasemapChanged(activeBasemap == basemap ? null : basemap),
          ),
        ],
      ],
    );
  }
}

class BasemapCard extends StatelessWidget {
  final String name;
  final String detail;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;

  const BasemapCard({
    super.key,
    required this.name,
    required this.detail,
    required this.icon,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(
              color: selected ? Colors.blueGrey : const Color(0xFFCCCCCC),
              width: selected ? 2 : 1,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(icon, color: Colors.blueGrey),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      detail,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.black54,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(
                  Icons.check_circle,
                  color: Colors.blueGrey,
                  size: 20,
                ),
            ],
          ),
        ),
      ),
    );
  }
}
