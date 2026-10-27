import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';

class CoordinateSearchDialog {
  static Future<LatLng?> show(BuildContext context) {
    return showDialog<LatLng>(
      context: context,
      builder: (_) => const _CoordinateSearchDialog(),
    );
  }
}

class _CoordinateSearchDialog extends StatefulWidget {
  const _CoordinateSearchDialog();

  @override
  State<_CoordinateSearchDialog> createState() =>
      _CoordinateSearchDialogState();
}

class _CoordinateSearchDialogState extends State<_CoordinateSearchDialog> {
  final _latitudeController = TextEditingController();
  final _longitudeController = TextEditingController();
  String? _errorMessage;

  @override
  void dispose() {
    _latitudeController.dispose();
    _longitudeController.dispose();
    super.dispose();
  }

  void _search() {
    final latitude = double.tryParse(_latitudeController.text.trim());
    final longitude = double.tryParse(_longitudeController.text.trim());

    if (latitude == null ||
        longitude == null ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude < -90 ||
        latitude > 90 ||
        longitude < -180 ||
        longitude > 180) {
      setState(() {
        _errorMessage = 'Masukkan latitude (-90 sampai 90) dan longitude (-180 sampai 180) yang valid.';
      });
      return;
    }

    Navigator.of(context).pop(LatLng(latitude, longitude));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Cari Koordinat'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _latitudeController,
              decoration: const InputDecoration(labelText: 'Latitude'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]')),
              ],
            ),
            TextField(
              controller: _longitudeController,
              decoration: const InputDecoration(labelText: 'Longitude'),
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
                signed: true,
              ),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]')),
              ],
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _errorMessage!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Batal'),
        ),
        FilledButton(onPressed: _search, child: const Text('Cari')),
      ],
    );
  }
}
