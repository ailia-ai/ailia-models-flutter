// for ailia SDK Predict api sample

import 'dart:io';
import 'dart:typed_data';
import 'package:ailia/ailia_model.dart';
import 'package:image/image.dart' as img;
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

  String run(img.Image image) {
    if (!_available) {
      throw Exception("Model not opened");
    }

    final resized = img.copyResize(
      image.convert(numChannels: 3),
      width: _imageSize,
      height: _imageSize,
      interpolation: img.Interpolation.linear,
    );
    final pixel = resized.getBytes(order: img.ChannelOrder.rgb);

    const mean = [0.485, 0.456, 0.406];
    const std = [0.229, 0.224, 0.225];

    AiliaTensor inputTensor = AiliaTensor();
    inputTensor.shape.x = _imageSize;
    inputTensor.shape.y = _imageSize;
    inputTensor.shape.z = 3;
    inputTensor.shape.w = 1;
    inputTensor.shape.dim = 4;
    inputTensor.data = Float32List(_imageSize * _imageSize * 3);

    for (int y = 0; y < _imageSize; y++) {
      for (int x = 0; x < _imageSize; x++) {
        for (int rgb = 0; rgb < 3; rgb++) {
          inputTensor.data[y * _imageSize + x + rgb * _imageSize * _imageSize] =
              (pixel[(_imageSize * y + x) * 3 + rgb] / 255.0 - mean[rgb]) /
                  std[rgb];
        }
      }
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

void ailiaEnvironmentSample(){
  List<AiliaEnvironment> envList = AiliaModel.getEnvironmentList();
  for (int i = 0; i < envList.length; i++){
    print("${envList[i].id} ${envList[i].name}");
  }
}

String ailiaPredictSample(File onnxFile, ByteData data){
  AiliaModel ailia = AiliaModel();
  ailia.openFile(onnxFile.path);

  const int numClass = 1000;
  const int imageSize = 224;
  const int imageCannels = 3;

  AiliaTensor inputTensor = AiliaTensor();
  inputTensor.shape.x = imageSize;
  inputTensor.shape.y = imageSize;
  inputTensor.shape.z = imageCannels;
  inputTensor.shape.w = 1;
  inputTensor.shape.dim = 4;
  inputTensor.data = Float32List(imageSize * imageSize * imageCannels);

  List pixel = data.buffer.asUint8List().toList();

  List mean = [0.485, 0.456, 0.406];
  List std = [0.229, 0.224, 0.225];

  for (int y = 0; y < imageSize; y++){
    for (int x = 0; x < imageSize; x++){
      for (int rgb = 0; rgb < 3; rgb++){
        inputTensor.data[y * imageSize + x + rgb * imageSize * imageSize] = (pixel[(imageSize * y + x) * 4 + rgb] / 255.0 - mean[rgb])/std[rgb];
      }
    }
  }

  List<AiliaTensor> output = ailia.run([inputTensor]);
  
  double maxProb = 0.0;
  int maxI = 0;
  for (int i = 0; i < numClass; i++){
    if (maxProb < output[0].data[i]){
      maxProb = output[0].data[i];
      maxI = i;
    }
  }

  return "Class : ${maxI} ${imagenet_category[maxI]} Confidence : ${maxProb}";
}
