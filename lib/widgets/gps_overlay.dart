import 'dart:math' as math;

import 'package:flutter/material.dart';

class GpsOverlay extends StatelessWidget {
  final VoidCallback onTap;
  final String status;
  final double? accuracy;
  final double? heading;
  final bool loading;

  const GpsOverlay({
    super.key,
    required this.onTap,
    required this.status,
    required this.accuracy,
    required this.heading,
    required this.loading,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.75),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.gps_fixed,
              color: Colors.lightGreenAccent,
              size: 16,
            ),
            const SizedBox(width: 4),
            Text(
              status,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              ' ±${accuracy?.toStringAsFixed(0) ?? '-'} m',
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
            const SizedBox(width: 8),
            CompassIndicator(heading: heading),
            if (loading) ...[
              const SizedBox(width: 6),
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: Colors.white70,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class CompassIndicator extends StatelessWidget {
  final double? heading;

  const CompassIndicator({super.key, required this.heading});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: heading == null
          ? 'Kompas tidak tersedia'
          : 'Arah ${heading!.round()}°',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Transform.rotate(
            angle: (heading ?? 0) * math.pi / 180,
            child: Icon(
              Icons.navigation,
              size: 14,
              color: heading == null ? Colors.white38 : Colors.orangeAccent,
            ),
          ),
          const SizedBox(width: 2),
          Text(
            heading == null ? '--°' : '${heading!.round()}°',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class GpsPositionMarker extends StatelessWidget {
  const GpsPositionMarker({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.blue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(color: Colors.black38, blurRadius: 4, spreadRadius: 1),
        ],
      ),
    );
  }
}
