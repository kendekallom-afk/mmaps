import 'package:flutter/material.dart';

class LayersView extends StatelessWidget {
  final int selectedTab;
  final ValueChanged<int> onTabChanged;

  const LayersView({
    super.key,
    required this.selectedTab,
    required this.onTabChanged,
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
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 76),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: const Color(0xFFCCCCCC)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.layers_clear_outlined, color: Colors.black45),
                      SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Belum ada layer aktif',
                          style: TextStyle(color: Colors.black54),
                        ),
                      ),
                    ],
                  ),
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
                  const EmptyLibrary(
                    icon: Icons.folder_open_outlined,
                    title: 'Maps Library',
                    message: 'Belum ada file peta untuk ditampilkan.',
                  )
                else
                  const BasemapChoices(),
              ],
            ),
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
  const BasemapChoices({super.key});

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        BasemapCard(
          name: 'OpenStreetMap',
          detail: 'Peta jalan',
          icon: Icons.map_outlined,
          selected: true,
        ),
        SizedBox(height: 10),
        BasemapCard(
          name: 'Satelit',
          detail: 'Citra satelit',
          icon: Icons.satellite_alt_outlined,
        ),
        SizedBox(height: 10),
        BasemapCard(
          name: 'Terrain',
          detail: 'Kontur dan relief',
          icon: Icons.terrain_outlined,
        ),
      ],
    );
  }
}

class BasemapCard extends StatelessWidget {
  final String name;
  final String detail;
  final IconData icon;
  final bool selected;

  const BasemapCard({
    super.key,
    required this.name,
    required this.detail,
    required this.icon,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
                Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                  detail,
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
          if (selected)
            const Icon(Icons.check_circle, color: Colors.blueGrey, size: 20),
        ],
      ),
    );
  }
}
