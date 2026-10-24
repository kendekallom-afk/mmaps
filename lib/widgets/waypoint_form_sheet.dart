import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../services/photo_service.dart';
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
  final PhotoService _photoService = PhotoService();

  bool _isSaving = false;
  bool _isPickingPhoto = false;
  
  final List<String> _photoPaths = [];
  final List<Uint8List> _webImageBytes = [];

  bool get _isEditing => widget.initialWaypoint != null;

    @override
  void initState() {
    super.initState();
    final w = widget.initialWaypoint;
    _nameCtrl = TextEditingController(text: w?.name ?? '');
    _descCtrl = TextEditingController(text: w?.description ?? '');
    
    // Pastikan list kosong terlebih dahulu (untuk mencegah duplikasi)
    _photoPaths.clear();
    _webImageBytes.clear();

    // Jika dalam mode edit, muat foto dari data waypoint
    if (w != null) {
      _photoPaths.addAll(w.photoPaths);
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSaving = true);

    final w = widget.initialWaypoint;
    final updatedWaypoint = w != null
        ? w.copyWith(
            name: _nameCtrl.text.trim(),
            description: _descCtrl.text.trim(),
            photoPaths: _photoPaths,
          )
        : Waypoint(
            id: DateTime.now().microsecondsSinceEpoch.toString(),
            name: _nameCtrl.text.trim(),
            description: _descCtrl.text.trim(),
            latitude: widget.initialLat,
            longitude: widget.initialLng,
            photoPaths: _photoPaths,
            createdAt: DateTime.now(),
          );

    Navigator.of(context).pop(WaypointSaved(updatedWaypoint));
  }

  Future<void> _pickPhoto(ImageSource source) async {
    if (_isPickingPhoto || _isSaving) return;
    setState(() => _isPickingPhoto = true);
    try {
      final XFile? pickedFile = await _photoService.pickImage(source);
      
      if (pickedFile != null) {
        if (kIsWeb) {
          final bytes = await pickedFile.readAsBytes();
          setState(() {
            _webImageBytes.add(bytes);
            _photoPaths.add(pickedFile.path); 
          });
        } else {
          final permanentPath = await _photoService.savePermanentImage(pickedFile);
          setState(() {
            _photoPaths.add(permanentPath);
          });
        }
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal memilih foto: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _isPickingPhoto = false);
    }
  }

  void _removePhoto(int index) {
    setState(() {
      _photoPaths.removeAt(index);
      if (kIsWeb && index < _webImageBytes.length) {
        _webImageBytes.removeAt(index);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF1E1E2E),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      // Padding horizontal dipertahankan, tapi padding bawah dikurangi karena foto akan full width
      padding: EdgeInsets.fromLTRB(20, 12, 20, 20 + bottomPadding),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
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
            Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
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
                  
                  // Tombol Tambah Foto
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isPickingPhoto || _isSaving
                              ? null
                              : () => _pickPhoto(ImageSource.camera),
                          style: _photoButtonStyle(),
                          icon: const Icon(Icons.camera_alt_outlined),
                          label: const Text('Kamera'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _isPickingPhoto || _isSaving
                              ? null
                              : () => _pickPhoto(ImageSource.gallery),
                          style: _photoButtonStyle(),
                          icon: const Icon(Icons.photo_library_outlined),
                          label: const Text('Galeri'),
                        ),
                      ),
                    ],
                  ),
                  if (_isPickingPhoto) ...[
                    const SizedBox(height: 8),
                    const LinearProgressIndicator(color: Colors.amber),
                  ],
                  
                  const SizedBox(height: 20),
                  
                  // Tombol Aksi (Simpan/Batal)
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

            // ==========================================
            // BAGIAN FOTO DILETAKKAN PALING BAWAH
            // ==========================================
            if (_photoPaths.isNotEmpty) ...[
              const SizedBox(height: 24),
              const Divider(color: Colors.white24),
              const SizedBox(height: 12),
              const Text(
                'Foto Pengamatan:',
                style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _photoPaths.length,
                itemBuilder: (context, index) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Stack(
                      children: [
                        // Gambar Penuh (Lebar 100%, Tinggi Menyesuaikan)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: _buildImage(index),
                        ),
                        // Tombol Hapus Foto
                        Positioned(
                          top: 8,
                          right: 8,
                          child: InkWell(
                            onTap: () => _removePhoto(index),
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: const BoxDecoration(
                                color: Colors.black54,
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(
                                Icons.close,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildImage(int index) {
    // Gunakan BoxFit.fitWidth agar foto mengikuti lebar layar (100%) 
    // dan tingginya menyesuaikan proporsi asli tanpa terpotong.
    if (kIsWeb && index < _webImageBytes.length) {
      return Image.memory(
        _webImageBytes[index],
        width: double.infinity,
        fit: BoxFit.fitWidth, // <-- Kunci agar tidak terpotong
      );
    } else if (!kIsWeb && index < _photoPaths.length) {
      return Image.file(
        File(_photoPaths[index]),
        width: double.infinity,
        fit: BoxFit.fitWidth, // <-- Kunci agar tidak terpotong
        errorBuilder: (context, error, stackTrace) => Container(
          height: 100,
          color: Colors.black26,
          child: const Center(
            child: Icon(Icons.broken_image, color: Colors.white38, size: 40),
          ),
        ),
      );
    }
    return const SizedBox();
  }

  ButtonStyle _photoButtonStyle() {
    return OutlinedButton.styleFrom(
      foregroundColor: Colors.white70,
      side: const BorderSide(color: Colors.white24),
      padding: const EdgeInsets.symmetric(vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
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