// ResNet18 image classification using the ailia SDK Predict API.

import 'dart:io';
import 'package:ailia/ailia_model.dart';
import 'package:image/image.dart' as img;
import '../utils/image_util.dart';
import 'imagenet_category.dart';

/// ResNet18 classifier that keeps the model open so it can be run
/// repeatedly (e.g. on live camera frames).
class ImageClassificationResNet18 {
  final AiliaModel _model = AiliaModel();
  bool _available = false;

  static const int _numClass = 1000;
  static const int _imageSize = 224;

  void open(File onnxFile, int envId) {
    if (_available) {
      return;
    }
    _model.openFile(onnxFile.path, envId: envId);
    _available = true;
  }

  void close() {
    if (!_available) {
      return;
    }
    _model.close();
    _available = false;
  }

  Future<String> run(img.Image image) async {
    if (!_available) {
      throw Exception("Model not opened");
    }

    final resized = img.copyResize(
      image.convert(numChannels: 3),
      width: _imageSize,
      height: _imageSize,
      interpolation: img.Interpolation.linear,
    );
    final inputTensor = await imageToAiliaTensor(resized);
    if (inputTensor == null) {
      throw Exception("Failed to convert image");
    }

    List<AiliaTensor> output = _model.run([inputTensor]);

    double maxProb = 0.0;
    int maxI = 0;
    for (int i = 0; i < _numClass; i++) {
      if (maxProb < output[0].data[i]) {
        maxProb = output[0].data[i];
        maxI = i;
      }
    }

    return "Class : $maxI ${imagenet_category[maxI]} Confidence : ${maxProb.toStringAsFixed(3)}";
  }
}
