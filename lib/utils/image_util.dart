import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ailia/ailia_model.dart';
import 'package:image/image.dart' as img;

Future<AiliaTensor?> imageToAiliaTensor(img.Image image,
    {int shapeZ = 3}) async {
  int numChannels = image.numChannels;
  if (shapeZ <= 0 || shapeZ > numChannels) {
    return null;
  }

  AiliaTensor inputTensor = _createAiliaTensor(
    Float32List(image.width * image.height * shapeZ),
    image.width,
    image.height,
    shapeZ,
  );

  List pixel = image.buffer.asUint8List().toList();

  List mean = [0.485, 0.456, 0.406];
  List std = [0.229, 0.224, 0.225];

  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      for (int c = 0; c < shapeZ; c++) {
        inputTensor.data[y * image.width + x + c * image.width * image.height] =
            (pixel[(image.width * y + x) * numChannels + c] / 255.0 - mean[c]) /
                std[c];
      }
    }
  }

  return inputTensor;
}

img.Image ailiaTensorToImage(AiliaTensor input, {bool reverse = false}) {
  final width = input.shape.x;
  final height = input.shape.y;
  final numChannels = input.shape.z;
  final data = input.data;

  final pixels = Uint8List(width * height * 4);

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final index = (y * width + x);
      pixels[index * 4 + 3] = (data[index * numChannels] * 255).toInt();
      if (reverse) {
        pixels[index * 4 + 3] = 255 - pixels[index * 4 + 3];
      }
    }
  }

  return img.Image.fromBytes(
    width: width,
    height: height,
    numChannels: 4,
    bytes: pixels.buffer,
  );
}

Future<img.Image> uiImageToImage(ui.Image image) async {
  final inputData = await image.toByteData(format: ui.ImageByteFormat.rawRgba);

  return img.Image.fromBytes(
    width: image.width,
    height: image.height,
    numChannels: 4,
    bytes: inputData!.buffer,
  );
}

Future<ui.Image> imageToUiImage(img.Image image) async {
  final bytes = img.encodePng(image);
  return _uint8ListToImage(bytes);
}

Future<ui.Image> _uint8ListToImage(Uint8List bytes) async {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromList(bytes, completer.complete);
  return completer.future;
}

AiliaTensor _createAiliaTensor(Float32List data, int x, int y, int z,
    {int w = 1, int dim = 4}) {
  final shape = AiliaShape();
  shape.x = x;
  shape.y = y;
  shape.z = z;
  shape.w = w;
  shape.dim = dim;

  AiliaTensor tensor = AiliaTensor();
  tensor.shape = shape;
  tensor.data = data;
  return tensor;
}
