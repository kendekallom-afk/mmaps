import 'package:flutter/material.dart';

import '../models/basemap.dart';

Future<Basemap?> showCustomXyzTilesSheet(BuildContext context) {
  return showModalBottomSheet<Basemap>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const CustomXyzTilesSheet(),
  );
}

class CustomXyzTilesSheet extends StatefulWidget {
  const CustomXyzTilesSheet({super.key});

  @override
  State<CustomXyzTilesSheet> createState() => _CustomXyzTilesSheetState();
}

class _CustomXyzTilesSheetState extends State<CustomXyzTilesSheet> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.of(context).pop(
      Basemap.custom(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        name: _nameController.text.trim(),
        xyzUrl: _urlController.text.trim(),
      ),
    );
  }

  String? _validateName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Nama basemap wajib diisi.';
    }
    return null;
  }

  String? _validateUrl(String? value) {
    final url = value?.trim() ?? '';
    if (url.isEmpty) return 'URL XYZ wajib diisi.';
    if (!url.contains('{z}') || !url.contains('{x}') || !url.contains('{y}')) {
      return 'URL harus memuat {z}, {x}, dan {y}.';
    }

    final uri = Uri.tryParse(url);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return 'Masukkan URL HTTP atau HTTPS yang valid.';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sheetHeight = MediaQuery.sizeOf(context).height * 0.5;
    return SafeArea(
      top: false,
      child: Container(
        height: sheetHeight,
        padding: EdgeInsets.only(
          left: 20,
          top: 12,
          right: 20,
          bottom: MediaQuery.viewInsetsOf(context).bottom + 16,
        ),
        decoration: const BoxDecoration(
          color: Color(0xFFF4F4F4),
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    width: 38,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.black26,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Add Custom XYZ Tiles',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                TextFormField(
                  key: const ValueKey('custom-xyz-name'),
                  controller: _nameController,
                  decoration: const InputDecoration(
                    labelText: 'Nama',
                    border: OutlineInputBorder(),
                  ),
                  textCapitalization: TextCapitalization.words,
                  validator: _validateName,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('custom-xyz-url'),
                  controller: _urlController,
                  decoration: const InputDecoration(
                    labelText: 'URL XYZ Tiles',
                    hintText: 'https://example.com/{z}/{x}/{y}.png',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.url,
                  validator: _validateUrl,
                ),
                const SizedBox(height: 14),
                FilledButton.icon(
                  key: const ValueKey('submit-custom-xyz-tiles'),
                  onPressed: _submit,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Custom XYZ Tiles'),
                  style: FilledButton.styleFrom(
                    backgroundColor: const Color(0xFF5D839E),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
