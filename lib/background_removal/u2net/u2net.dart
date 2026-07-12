import 'package:ailia/ailia_model.dart';
import 'package:image/image.dart' as img;
import 'package:ailia_models_flutter/utils/image_util.dart';
import 'dart:async';

const imageSize = 320;

class U2Net {
  final AiliaModel _model = AiliaModel();
  int _inputWidth = 0;
  int _inputHeight = 0;
  AiliaTensor? _inputTensor;
  bool _available = false;

  void open(String modelFilePath, {int envId = 0, int memoryMode = 11}) {
    _model.openFile(modelFilePath, envId: envId, memoryMode: memoryMode);
    _available = true;
  }

  void close() {
    if (!_available) {
      return;
    }

    _model.close();
    _available = false;
  }

  Future<bool> setImage(
    img.Image image,
  ) async {
    _inputWidth = image.width;
    _inputHeight = image.height;
    final resizedImage = img.copyResize(
      image,
      width: imageSize,
      height: imageSize,
      interpolation: img.Interpolation.linear,
    );
    _inputTensor = await imageToAiliaTensor(resizedImage);

    return true;
  }

  img.Image? run() {
    if (_inputWidth == 0 || _inputHeight == 0 || _inputTensor == null) {
      return null;
    }

    List<AiliaTensor> outputs = _model.run([_inputTensor!]);
    AiliaTensor mask = outputs[0];

    final maskImage = ailiaTensorToImage(mask, reverse: true);
    return img.copyResize(
      maskImage,
      width: _inputWidth,
      height: _inputHeight,
      interpolation: img.Interpolation.linear,
    );
  }
}
