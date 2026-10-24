import 'dart:io';

import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

class PhotoService {
  final ImagePicker _imagePicker;

  PhotoService({ImagePicker? imagePicker})
    : _imagePicker = imagePicker ?? ImagePicker();

  Future<String?> pickAndSaveImage(ImageSource source) async {
    final image = await _imagePicker.pickImage(source: source);
    if (image == null) return null;

    final documentsDirectory = await getApplicationDocumentsDirectory();
    final fileName =
        'waypoint_${DateTime.now().microsecondsSinceEpoch}'
        '${path.extension(image.path)}';
    final savedPath = path.join(documentsDirectory.path, fileName);
    await File(image.path).copy(savedPath);
    return savedPath;
  }
}
