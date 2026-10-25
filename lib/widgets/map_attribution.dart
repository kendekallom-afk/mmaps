import 'package:flutter/material.dart';

class MapAttribution extends StatelessWidget {
  final String? attribution;

  const MapAttribution({super.key, this.attribution});

  @override
  Widget build(BuildContext context) {
    if (attribution == null) return const SizedBox.shrink();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          attribution!,
          style: const TextStyle(fontSize: 10, color: Colors.black87),
        ),
      ),
    );
  }
}
