
import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class PhotoService {
  final ImagePicker _imagePicker;

  PhotoService({ImagePicker? imagePicker})
      : _imagePicker = imagePicker ?? ImagePicker();

  /// Memilih foto dari kamera atau galeri.
  Future<XFile?> pickImage(ImageSource source) async {
    return await _imagePicker.pickImage(source: source);
  }

  /// Menyimpan foto ke direktori permanen aplikasi.
  Future<String> savePermanentImage(XFile image) async {
    final documentsDirectory = await getApplicationDocumentsDirectory();

    final extension = path.extension(image.path);
    final fileName =
        'waypoint_${DateTime.now().microsecondsSinceEpoch}'
        '${extension.isEmpty ? '.jpg' : extension}';

    final savedPath = path.join(documentsDirectory.path, fileName);

    final bytes = await image.readAsBytes();

    if (bytes.isEmpty) {
      throw StateError('Foto yang dipilih tidak memiliki data.');
    }

    final savedFile = File(savedPath);
    await savedFile.writeAsBytes(bytes, flush: true);

    if (!await savedFile.exists() || await savedFile.length() == 0) {
      throw FileSystemException(
        'Foto gagal disimpan secara permanen.',
        savedPath,
      );
    }

    return savedPath;
  }
}
