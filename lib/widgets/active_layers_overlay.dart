import 'package:flutter/material.dart';

class ActiveLayersOverlay extends StatelessWidget {
  final List<String> layers;
  final ValueChanged<String>? onLayerTap; // <-- Tambahkan parameter ini

  const ActiveLayersOverlay({
    super.key, 
    required this.layers,
    this.onLayerTap, // <-- Tambahkan ini
  });

  @override
  Widget build(BuildContext context) {
    if (layers.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 2), // Padding vertikal disesuaikan
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: layers
            .map(
              (l) => InkWell(
                onTap: onLayerTap != null ? () => onLayerTap!(l) : null, // <-- Aksi klik
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), // Padding pindah ke dalam
                  child: Text(
                    l,
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}