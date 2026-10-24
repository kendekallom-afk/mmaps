import 'package:flutter/material.dart';

import '../models/waypoint.dart';

sealed class WaypointFormResult {
  const WaypointFormResult();
}

class WaypointSaved extends WaypointFormResult {
  final Waypoint waypoint;

  const WaypointSaved(this.waypoint);
}

class WaypointDeleted extends WaypointFormResult {
  final String waypointId;

  const WaypointDeleted(this.waypointId);
}

/// Menampilkan bottom sheet form untuk menambah atau mengedit [Waypoint].
///
/// Gunakan [show] untuk memunculkan sheet ini. Hasilnya menunjukkan apakah
/// waypoint disimpan, dihapus, atau sheet dibatalkan.
class WaypointFormSheet extends StatefulWidget {
  final double initialLat;
  final double initialLng;
  final Waypoint? initialWaypoint;

  const WaypointFormSheet({
    super.key,
    required this.initialLat,
    required this.initialLng,
    this.initialWaypoint,
  });

  /// Helper statis untuk memunculkan sheet dan mengembalikan hasilnya.
  static Future<WaypointFormResult?> show(
    BuildContext context, {
    required double initialLat,
    required double initialLng,
    Waypoint? initialWaypoint,
  }) {
    return showModalBottomSheet<WaypointFormResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => WaypointFormSheet(
        initialLat: initialLat,
        initialLng: initialLng,
        initialWaypoint: initialWaypoint,
      ),
    );
  }

  @override
  State<WaypointFormSheet> createState() => _WaypointFormSheetState();
}

class _WaypointFormSheetState extends State<WaypointFormSheet> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameCtrl;
  late final TextEditingController _descCtrl;

  bool _isSaving = false;

  bool get _isEditing => widget.initialWaypoint != null;

  @override
  void initState() {
    super.initState();
    final w = widget.initialWaypoint;
    _nameCtrl = TextEditingController(text: w?.name ?? '');
    _descCtrl = TextEditingController(text: w?.description ?? '');
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Aksi
  // ---------------------------------------------------------------------------

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    final w = widget.initialWaypoint;
    final updatedWaypoint = w != null
        ? w.copyWith(
            name: _nameCtrl.text.trim(),
            description: _descCtrl.text.trim(),
          )
        : Waypoint(
            name: _nameCtrl.text.trim(),
            description: _descCtrl.text.trim(),
            latitude: widget.initialLat,
            longitude: widget.initialLng,
          );

    Navigator.of(context).pop(WaypointSaved(updatedWaypoint));
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomPadding),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white24,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          // Header
          Row(
            children: [
              Icon(
                _isEditing
                    ? Icons.edit_location_alt_outlined
                    : Icons.add_location_alt_outlined,
                color: Colors.amber,
                size: 22,
              ),
              const SizedBox(width: 8),
              Text(
                _isEditing ? 'Edit Titik' : 'Tambah Titik Baru',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              // Koordinat (readonly)
              Text(
                '${widget.initialLat.toStringAsFixed(6)},\n'
                '${widget.initialLng.toStringAsFixed(6)}',
                textAlign: TextAlign.right,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                  fontFamily: 'monospace',
                  height: 1.4,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Form
          Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Nama
                TextFormField(
                  controller: _nameCtrl,
                  autofocus: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: _inputDecoration(
                    label: 'Nama Titik *',
                    icon: Icons.label_outline,
                  ),
                  validator: (v) => (v == null || v.trim().isEmpty)
                      ? 'Nama tidak boleh kosong'
                      : null,
                ),
                const SizedBox(height: 12),

                // Deskripsi
                TextFormField(
                  controller: _descCtrl,
                  style: const TextStyle(color: Colors.white),
                  maxLines: 3,
                  decoration: _inputDecoration(
                    label: 'Deskripsi (opsional)',
                    icon: Icons.notes_outlined,
                  ),
                ),
                const SizedBox(height: 16),

                // Foto section
                _buildPhotoSection(),
                const SizedBox(height: 20),

                // Tombol aksi
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _isSaving
                            ? null
                            : () => Navigator.of(context).pop(),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white54,
                          side: const BorderSide(color: Colors.white24),
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: const Text('Batal'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: _isSaving ? null : _save,
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.amber,
                          foregroundColor: Colors.black87,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        icon: _isSaving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.black54,
                                ),
                              )
                            : const Icon(Icons.save_outlined, size: 18),
                        label: Text(_isEditing ? 'Perbarui' : 'Simpan'),
                      ),
                    ),
                  ],
                ),
                if (_isEditing) ...[
                  const SizedBox(height: 10),
                  TextButton.icon(
                    onPressed: _isSaving
                        ? null
                        : () => Navigator.of(context)
                              .pop(WaypointDeleted(widget.initialWaypoint!.id)),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Hapus Waypoint'),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPhotoSection() {
    return OutlinedButton.icon(
      onPressed: () {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pemilihan foto belum tersedia.')),
        );
      },
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white70,
        side: const BorderSide(color: Colors.white24),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: const Icon(Icons.add_a_photo_outlined),
      label: const Text('Tambah Foto (opsional)'),
    );
  }

  InputDecoration _inputDecoration({
    required String label,
    required IconData icon,
  }) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54),
      prefixIcon: Icon(icon, color: Colors.white38, size: 20),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.06),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white12),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.white12),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.amber, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: Colors.redAccent),
      ),
    );
  }
}
