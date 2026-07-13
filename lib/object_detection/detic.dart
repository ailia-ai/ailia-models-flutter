// Detic: open-vocabulary object detection and instance segmentation
// over the LVIS vocabulary (1203 classes), ported from
// ailia-models/object_detection/detic and the Unity Foundation sample.

import 'dart:typed_data';

import 'package:ailia/ailia_model.dart';
import 'package:image/image.dart' as img;

import 'lvis_categories.dart';

/// Colors assigned to instances in the mask overlay, matching the box
/// palette of the overlay painter.
const List<List<int>> _maskPalette = [
  [244, 67, 54], // red
  [205, 220, 57], // lime
  [33, 150, 243], // blue
  [255, 235, 59], // yellow
  [0, 188, 212], // cyan
  [255, 152, 0], // orange
  [156, 39, 176], // purple
  [233, 30, 99], // pink
];

class DeticResult {
  DeticResult(this.boxes, this.maskOverlay);

  /// Detected instances with normalized (0..1) coordinates.
  final List<AiliaDetectorObject> boxes;

  /// Colored instance masks as a translucent RGBA overlay at the
  /// detection resolution, or null when nothing was detected.
  final img.Image? maskOverlay;
}

class Detic {
  final AiliaModel _model = AiliaModel();
  bool _available = false;

  /// Remote (folder, filename) of the model, shared with the download
  /// list. Detic does not work on FP16 environments, so it runs on the
  /// CPU environment.
  static const List<(String, String)> modelFiles = [
    ('detic', 'Detic_C2_SwinB_896_4x_IN-21K+COCO_lvis_op16.onnx'),
  ];

  List<String> get category => lvisCategories;

  void open(String modelPath, {int envId = 0}) {
    // The SwinB model is large; open with the memory-reducing mode.
    _model.openFile(modelPath, envId: envId, memoryMode: 11);
    _available = true;
  }

  void close() {
    if (!_available) {
      return;
    }
    _model.close();
    _available = false;
  }

  /// Runs detection on [image], resized so that its longest side is
  /// [detectionWidth] (the recognition resolution). Returns the
  /// detected boxes in normalized coordinates and the instance mask
  /// overlay.
  DeticResult run(img.Image image, int detectionWidth) {
    // Fit the image into detectionWidth x detectionWidth, keeping the
    // aspect ratio (the same sizing as the python preprocess).
    final imW = image.width;
    final imH = image.height;
    double scale = detectionWidth / (imW < imH ? imW : imH);
    double ow = imW * scale;
    double oh = imH * scale;
    if ((ow > oh ? ow : oh) > detectionWidth) {
      final cap = detectionWidth / (ow > oh ? ow : oh);
      ow *= cap;
      oh *= cap;
    }
    final w = (ow + 0.5).toInt();
    final h = (oh + 0.5).toInt();

    final resized = img.copyResize(
      image,
      width: w,
      height: h,
      interpolation: img.Interpolation.linear,
    );

    // RGB values 0..255 as NCHW float (Detic takes unnormalized pixels).
    final imageTensor = _tensor(w, h, 3, 4);
    final rgb =
        resized.convert(numChannels: 3).getBytes(order: img.ChannelOrder.rgb);
    final planeSize = w * h;
    for (int i = 0; i < planeSize; i++) {
      imageTensor.data[i] = rgb[i * 3].toDouble();
      imageTensor.data[i + planeSize] = rgb[i * 3 + 1].toDouble();
      imageTensor.data[i + planeSize * 2] = rgb[i * 3 + 2].toDouble();
    }

    // The second input selects the output resolution; the model scales
    // the boxes and pastes the masks at this size. Passing the resized
    // size (instead of the original size like the python sample) keeps
    // the mask memory bounded on mobile.
    final hwTensor = _tensor(2, 1, 1, 1);
    hwTensor.data[0] = h.toDouble();
    hwTensor.data[1] = w.toDouble();

    final outputs = _model.run([imageTensor, hwTensor]);
    final boxData = outputs[0]; // (N, 4) x0,y0,x1,y1 in resized coords
    final scoreData = outputs[1]; // (N)
    final classData = outputs[2]; // (N)
    final maskData = outputs[3]; // (N, h, w)

    final count = boxData.shape.y;
    final boxes = <AiliaDetectorObject>[];
    for (int i = 0; i < count; i++) {
      final box = AiliaDetectorObject();
      box.x = boxData.data[i * 4] / w;
      box.y = boxData.data[i * 4 + 1] / h;
      box.w = boxData.data[i * 4 + 2] / w - box.x;
      box.h = boxData.data[i * 4 + 3] / h - box.y;
      box.category = classData.data[i].toInt();
      box.prob = scoreData.data[i];
      boxes.add(box);
    }

    return DeticResult(boxes, _buildMaskOverlay(maskData, count));
  }

  /// Combines the per-instance masks into one translucent colored
  /// overlay image.
  img.Image? _buildMaskOverlay(AiliaTensor maskData, int count) {
    if (count < 1) {
      return null;
    }
    final w = maskData.shape.x;
    final h = maskData.shape.y;
    final planeSize = w * h;
    final rgba = Uint8List(planeSize * 4);
    for (int c = 0; c < count && c < maskData.shape.z; c++) {
      final color = _maskPalette[c % _maskPalette.length];
      for (int i = 0; i < planeSize; i++) {
        if (maskData.data[c * planeSize + i] > 0.5) {
          rgba[i * 4] = (rgba[i * 4] + color[0]).clamp(0, 255);
          rgba[i * 4 + 1] = (rgba[i * 4 + 1] + color[1]).clamp(0, 255);
          rgba[i * 4 + 2] = (rgba[i * 4 + 2] + color[2]).clamp(0, 255);
          rgba[i * 4 + 3] = 180;
        }
      }
    }
    return img.Image.fromBytes(
        width: w, height: h, numChannels: 4, bytes: rgba.buffer);
  }

  AiliaTensor _tensor(int x, int y, int z, int dim) {
    final shape = AiliaShape();
    shape.x = x;
    shape.y = y;
    shape.z = z;
    shape.w = 1;
    shape.dim = dim;
    final tensor = AiliaTensor();
    tensor.shape = shape;
    tensor.data = Float32List(x * y * z);
    return tensor;
  }
}
