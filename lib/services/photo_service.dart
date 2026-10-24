import 'dart:io';

import 'package:flutter/foundation.dart'; // Untuk kIsWeb
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class PhotoService {
  final ImagePicker _imagePicker;

  PhotoService({ImagePicker? imagePicker})
      : _imagePicker = imagePicker ?? ImagePicker();

  /// Memilih gambar dari kamera atau galeri.
  Future<XFile?> pickImage(ImageSource source) async {
    return await _imagePicker.pickImage(source: source);
  }

  /// Menyimpan gambar secara permanen di direktori aplikasi (Hanya untuk Android/iOS).
  /// Mengembalikan path file yang baru.
  Future<String> savePermanentImage(XFile image) async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    final fileName =
        'waypoint_${DateTime.now().microsecondsSinceEpoch}'
        '${path.extension(image.path)}';
    final savedPath = path.join(documentsDirectory.path, fileName);
    
    await File(image.path).copy(savedPath);
    return savedPath;
  }
}