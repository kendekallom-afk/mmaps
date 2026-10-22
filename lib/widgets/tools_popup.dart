import 'package:flutter/material.dart';

class ToolsPopup extends StatelessWidget {
  final VoidCallback onClose;
  final VoidCallback onFindByCoordinate;
  final VoidCallback onRecordTrack;
  final VoidCallback onMeasure;
  final VoidCallback onMapFeatures;
  final VoidCallback onSettings;

  const ToolsPopup({
    super.key,
    required this.onClose,
    required this.onFindByCoordinate,
    required this.onRecordTrack,
    required this.onMeasure,
    required this.onMapFeatures,
    required this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 6,
      color: Colors.grey.shade900,
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: 220,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(
                left: 12,
                top: 8,
                right: 4,
                bottom: 4,
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Menu Alat',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    onPressed: onClose,
                    tooltip: 'Tutup menu alat',
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white70,
                      size: 18,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),
            _item('Find By Coordinates', onFindByCoordinate),
            _item('Record GPS Tracks', onRecordTrack),
            _item('Measure Distance or Area', onMeasure),
            _item('Map Features', onMapFeatures),
            _item('Settings', onSettings),
          ],
        ),
      ),
    );
  }

  Widget _item(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
      ),
    );
  }
}
