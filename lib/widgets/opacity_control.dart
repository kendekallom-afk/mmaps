import 'package:flutter/material.dart';

class OpacityControl extends StatelessWidget {
  final bool expanded;
  final double value;
  final VoidCallback onToggle;
  final ValueChanged<double> onChanged;

  const OpacityControl({
    super.key,
    required this.expanded,
    required this.value,
    required this.onToggle,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.contrast, color: Colors.white, size: 20),
            tooltip: 'Transparansi peta',
            onPressed: onToggle,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: EdgeInsets.zero,
          ),
          if (expanded) ...[
            const SizedBox(height: 4),
            RotatedBox(
              quarterTurns: 3,
              child: SizedBox(
                width: 90,
                child: Slider(
                  value: value,
                  min: 0,
                  max: 100,
                  onChanged: onChanged,
                ),
              ),
            ),
            Text(
              '${value.round()}%',
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }
}
