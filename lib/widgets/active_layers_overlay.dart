import 'package:flutter/material.dart';

class ActiveLayersOverlay extends StatelessWidget {
  final List<String> layers;

  const ActiveLayersOverlay({super.key, required this.layers});

  @override
  Widget build(BuildContext context) {
    if (layers.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: layers
            .map(
              (l) => Text(
                l,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            )
            .toList(),
      ),
    );
  }
}
