// Image classification (ResNet50 / ViT-B16) using the ailia SDK
// Predict API.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:ailia/ailia_model.dart';
import 'package:image/image.dart' as img;
import '../utils/image_util.dart';
import 'imagenet_category.dart';

/// Common surface of the classification demos, so the demo page can
/// drive every classifier through the same still / realtime path.
abstract class ImageClassifier {
  /// Opens the model; the instance stays open so it can be run
  /// repeatedly (e.g. on live camera frames).
  void open(File onnxFile, int envId);

  void close();

  /// Classifies [image] and returns the result lines to display.
  Future<String> run(img.Image image);
}

const int _numClass = 1000;
const int _topN = 3;

/// Softmax over [logits] (max-subtracted for numerical stability).
Float32List _softmax(Float32List logits) {
  double maxLogit = logits[0];
  for (int i = 1; i < _numClass; i++) {
    if (logits[i] > maxLogit) {
      maxLogit = logits[i];
    }
  }
  final probabilities = Float32List(_numClass);
  double expSum = 0.0;
  for (int i = 0; i < _numClass; i++) {
    probabilities[i] = math.exp(logits[i] - maxLogit).toDouble();
    expSum += probabilities[i];
  }
  for (int i = 0; i < _numClass; i++) {
    probabilities[i] /= expSum;
  }
  return probabilities;
}

/// Result lines for the most probable ImageNet classes.
String _formatTopClasses(Float32List probabilities) {
  final indices = List<int>.generate(_numClass, (i) => i)
    ..sort((a, b) => probabilities[b].compareTo(probabilities[a]));
  final lines = <String>[];
  for (int rank = 0; rank < _topN; rank++) {
    final i = indices[rank];
    lines.add("Top${rank + 1} : ${imagenet_category[i]}"
        " Confidence : ${probabilities[i].toStringAsFixed(3)}");
  }
  return lines.join("\n");
}

/// ResNet50 (torchvision export) with ImageNet mean / std input
/// normalization.
class ImageClassificationResNet50 implements ImageClassifier {
  final AiliaModel _model = AiliaModel();
  bool _available = false;

  static const int _imageSize = 224;

  @override
  void open(File onnxFile, int envId) {
    if (_available) {
      return;
    }
    _model.openFile(onnxFile.path, envId: envId);
    _available = true;
  }

  @override
  void close() {
    if (!_available) {
      return;
    }
    _model.close();
    _available = false;
  }

  @override
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

    return _formatTopClasses(_softmax(output[0].data));
  }
}

/// ViT-B/16 image classification (ported from ailia-models-kotlin's
/// AiliaOnnxClassificationSample): bilinear resize to 224x224, RGB
/// scaled to [-1, 1], BCHW input; softmax over the output logits.
class ImageClassificationViT implements ImageClassifier {
  final AiliaModel _model = AiliaModel();
  bool _available = false;

  static const int _imageSize = 224;

  @override
  void open(File onnxFile, int envId) {
    if (_available) {
      return;
    }
    _model.openFile(onnxFile.path, envId: envId);
    _available = true;
  }

  @override
  void close() {
    if (!_available) {
      return;
    }
    _model.close();
    _available = false;
  }

  @override
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

    // RGB scaled to [-1, 1] in CHW order.
    final pixels = resized.getBytes(order: img.ChannelOrder.rgb);
    final data = Float32List(_imageSize * _imageSize * 3);
    const pixelCount = _imageSize * _imageSize;
    for (int i = 0; i < pixelCount; i++) {
      for (int c = 0; c < 3; c++) {
        data[c * pixelCount + i] = pixels[i * 3 + c] / 127.5 - 1.0;
      }
    }
    final shape = AiliaShape();
    shape.x = _imageSize;
    shape.y = _imageSize;
    shape.z = 3;
    shape.w = 1;
    shape.dim = 4;
    final inputTensor = AiliaTensor();
    inputTensor.shape = shape;
    inputTensor.data = data;

    List<AiliaTensor> output = _model.run([inputTensor]);

    return _formatTopClasses(_softmax(output[0].data));
  }
}
