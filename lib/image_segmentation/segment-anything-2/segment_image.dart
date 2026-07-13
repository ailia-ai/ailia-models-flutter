import 'package:ailia/ailia_model.dart';
import 'sam2_image_predictor.dart';

import 'package:image/image.dart' as img;

import 'package:flutter/services.dart'; //rootBundle
import 'dart:async'; //Future

class SegmentImage {
  final Sam2ImagePredictor _predictor = Sam2ImagePredictor();
  final AiliaModel _imageEncoder = AiliaModel();
  final AiliaModel _promptEncoder = AiliaModel();
  final AiliaModel _maskDecoder = AiliaModel();
  AiliaTensor? _imageFeature;
  List<AiliaTensor>? _highResFeatures;
  bool _available = false;

  void open(String imageEncoderModelFilePath, String promptEncoderModelFilePath,
      String maskEncoderModelFilePath,
      {int envId = 0, int memoryMode = 11}) {
    _imageEncoder.openFile(imageEncoderModelFilePath,
        envId: envId, memoryMode: memoryMode);
    _promptEncoder.openFile(promptEncoderModelFilePath,
        envId: envId, memoryMode: memoryMode);
    _maskDecoder.openFile(maskEncoderModelFilePath,
        envId: envId, memoryMode: memoryMode);
    _available = true;
  }

  void close() {
    if (!_available) {
      return;
    }

    _imageEncoder.close();
    _promptEncoder.close();
    _maskDecoder.close();

    _available = false;
  }

  Future<bool> setImage(
    img.Image image,
  ) async {
    _imageFeature = null;
    _highResFeatures = null;

    final features = await _predictor.setImage(image, _imageEncoder);
    if (features.isEmpty) {
      return false;
    }

    _imageFeature = features[0];
    _highResFeatures = features.sublist(1);
    return true;
  }

  img.Image? run(List<img.Point> pointCoords) {
    if (_imageFeature == null || _highResFeatures == null) {
      return null;
    }

    List<int> pointLabels = [];
    for (int i = 0; i < pointCoords.length; i++) {
      pointLabels.add(1);
    }

    return _predictor.predict(
      _imageFeature!,
      _highResFeatures!,
      pointCoords,
      pointLabels,
      _promptEncoder,
      _maskDecoder,
    );
  }

  Future<img.Image> overlayMaskImage(
      img.Image srcImage, img.Image maskImage) async {
    final width = maskImage.width;
    final height = maskImage.height;
    if (width != maskImage.width || height != maskImage.height) {
      return srcImage;
    }

    final mask = maskImage.data!.toUint8List();
    final pixels = srcImage.data!.toUint8List();
    final srcChannels = srcImage.numChannels;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final index = (y * width + x) * srcChannels;
        final maskValue = mask[(y * width + x) * maskImage.numChannels +
                maskImage.numChannels -
                1] ~/
            5;
        pixels[index] = _clamp(pixels[index] + maskValue, 0, 255);
      }
    }

    final image = img.Image.fromBytes(
        width: width,
        height: height,
        numChannels: srcChannels,
        bytes: pixels.buffer);
    return image;
  }

  int _clamp(int value, int min, int max) {
    return value < min
        ? min
        : value > max
            ? max
            : value;
  }
}
