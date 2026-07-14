// SAM 3.1: open-vocabulary instance segmentation with text prompts,
// ported from ailia-models/image_segmentation/segment-anything-3.1
// (static image mode; the tracking / memory attention pipeline is not
// ported).

import 'dart:math';
import 'dart:typed_data';

import 'package:ailia/ailia_model.dart';
import 'package:ailia_tokenizer/ailia_tokenizer.dart' as ailia_tokenizer_dart;
import 'package:ailia_tokenizer/ailia_tokenizer_model.dart';
import 'package:image/image.dart' as img;

/// Colors assigned to instances in the mask overlay, matching the box
/// palette of the overlay painter (boxes carry the instance index as
/// their category so both pick the same color).
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

class Sam3Result {
  Sam3Result(this.boxes, this.maskOverlay);

  /// Detected instances with normalized (0..1) coordinates. The
  /// category field holds the instance index, so the overlay painter
  /// colors each box like its mask.
  final List<AiliaDetectorObject> boxes;

  /// Colored instance masks as a translucent RGBA overlay at the mask
  /// resolution of the model, or null when nothing was detected.
  final img.Image? maskOverlay;
}

class SegmentAnything3 {
  static const int imageSize = 1008;
  static const int contextLength = 32;
  static const double confidenceThreshold = 0.5;

  static const int _sotToken = 49406;
  static const int _eotToken = 49407;

  final AiliaModel _imageEncoder = AiliaModel();
  final AiliaModel _grounding = AiliaModel();
  final AiliaTokenizerModel _tokenizer = AiliaTokenizerModel();
  bool _encoderAvailable = false;
  bool _groundingAvailable = false;

  // Encoder features cached by setImage, consumed by run.
  AiliaTensor? _fpn0;
  AiliaTensor? _fpn1;
  AiliaTensor? _fpn2;
  AiliaTensor? _pos2;

  bool get hasImage => _fpn0 != null;

  void open(String imageEncoderModelFilePath, String groundingModelFilePath,
      {int envId = 0, int memoryMode = 11}) {
    // Both models are over 1.5 GB, so open with the memory-reducing
    // mode. SAM 3.1 does not work on FP16 environments.
    _imageEncoder.openFile(imageEncoderModelFilePath,
        envId: envId, memoryMode: memoryMode);
    _encoderAvailable = true;
    _grounding.openFile(groundingModelFilePath,
        envId: envId, memoryMode: memoryMode);
    _groundingAvailable = true;
    // The CLIP BPE tokenizer is built into ailia Tokenizer; no vocab
    // file is needed.
    _tokenizer.openFile(ailia_tokenizer_dart.AILIA_TOKENIZER_TYPE_CLIP);
  }

  /// Frees the image encoder while keeping the cached features and the
  /// grounding model, so still-image demos can re-run new text prompts
  /// without holding both multi-GB models in memory.
  void releaseEncoder() {
    if (_encoderAvailable) {
      _imageEncoder.close();
      _encoderAvailable = false;
    }
  }

  void close() {
    releaseEncoder();
    if (_groundingAvailable) {
      _grounding.close();
      _tokenizer.close();
      _groundingAvailable = false;
    }
    _fpn0 = null;
    _fpn1 = null;
    _fpn2 = null;
    _pos2 = null;
  }

  /// Encodes [image] with the image encoder and caches the feature
  /// pyramid used by [run].
  Future<void> setImage(img.Image image) async {
    if (!_encoderAvailable) {
      throw Exception("Image encoder not opened");
    }
    _fpn0 = null;

    final resized = img.copyResize(
      image,
      width: imageSize,
      height: imageSize,
      interpolation: img.Interpolation.linear,
    );
    final rgb =
        resized.convert(numChannels: 3).getBytes(order: img.ChannelOrder.rgb);

    // RGB normalized to [-1, 1] as NCHW: (x / 255 - 0.5) / 0.5.
    final input = _tensor(imageSize, imageSize, 3, 4);
    const planeSize = imageSize * imageSize;
    for (int i = 0; i < planeSize; i++) {
      input.data[i] = rgb[i * 3] / 127.5 - 1.0;
      input.data[i + planeSize] = rgb[i * 3 + 1] / 127.5 - 1.0;
      input.data[i + planeSize * 2] = rgb[i * 3 + 2] / 127.5 - 1.0;
    }

    // Outputs: fpn0, fpn1, fpn2, pos0, pos1, pos2, then the tracking
    // path features (unused in static image mode).
    final outputs = _imageEncoder.run([input]);
    _fpn0 = outputs[0];
    _fpn1 = outputs[1];
    _fpn2 = outputs[2];
    _pos2 = outputs[5];
  }

  /// Segments every instance matching the [text] prompt on the image
  /// set by [setImage].
  Sam3Result run(String text, {double threshold = confidenceThreshold}) {
    if (!_groundingAvailable || _fpn0 == null) {
      throw Exception("Image not set");
    }

    final tokens = _tokenize(text);

    // Text-only prompt: ailia does not support zero-length blobs, so
    // pass one dummy box marked as padding via box_mask = True (the
    // same workaround as the python sample's ailia path).
    final boxCoords = _tensor(4, 1, 1, 3);
    final boxLabels = _tensor(1, 1, 1, 2);
    final boxMask = _tensor(1, 1, 1, 2);
    boxMask.data[0] = 1.0;

    final outputs = _grounding.run([
      _fpn0!,
      _fpn1!,
      _fpn2!,
      _pos2!,
      tokens,
      boxCoords,
      boxLabels,
      boxMask,
    ]);
    final predMasks = outputs[0]; // (1, 200, mask_h, mask_w) logits
    final predBoxes = outputs[1]; // (1, 200, 4) normalized cxcywh
    final predLogits = outputs[2]; // (1, 200, 1)
    final presenceLogit = outputs[3]; // (1, 1)

    // Per-query score = sigmoid(query logit) * sigmoid(presence logit).
    // The DETR-style query head needs no NMS.
    final presence = _sigmoid(presenceLogit.data[0]);
    final numQueries = predLogits.data.length;
    final kept = <int>[];
    final boxes = <AiliaDetectorObject>[];
    for (int q = 0; q < numQueries; q++) {
      final score = _sigmoid(predLogits.data[q]) * presence;
      if (score <= threshold) {
        continue;
      }
      final cx = predBoxes.data[q * 4];
      final cy = predBoxes.data[q * 4 + 1];
      final bw = predBoxes.data[q * 4 + 2];
      final bh = predBoxes.data[q * 4 + 3];
      final box = AiliaDetectorObject();
      box.x = cx - bw / 2;
      box.y = cy - bh / 2;
      box.w = bw;
      box.h = bh;
      box.category = kept.length;
      box.prob = score;
      boxes.add(box);
      kept.add(q);
    }

    return Sam3Result(boxes, _buildMaskOverlay(predMasks, kept));
  }

  /// Combines the kept per-query mask logits into one translucent
  /// colored overlay image at the mask resolution (a mask pixel is set
  /// where its logit > 0, i.e. sigmoid > 0.5).
  img.Image? _buildMaskOverlay(AiliaTensor predMasks, List<int> kept) {
    if (kept.isEmpty) {
      return null;
    }
    final w = predMasks.shape.x;
    final h = predMasks.shape.y;
    final planeSize = w * h;
    final rgba = Uint8List(planeSize * 4);
    for (int c = 0; c < kept.length; c++) {
      final color = _maskPalette[c % _maskPalette.length];
      final offset = kept[c] * planeSize;
      for (int i = 0; i < planeSize; i++) {
        if (predMasks.data[offset + i] > 0.0) {
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

  /// CLIP-tokenizes [text] into the fixed (1, 32) prompt tensor:
  /// <start of text>, the BPE tokens, <end of text>, zero padding.
  AiliaTensor _tokenize(String text) {
    final encoded = _tokenizer.encode(text).toList();
    // ailia Tokenizer may or may not add the special tokens depending
    // on its version; normalize to exactly one SOT / EOT pair.
    if (encoded.isEmpty || encoded.first != _sotToken) {
      encoded.insert(0, _sotToken);
    }
    if (encoded.last != _eotToken) {
      encoded.add(_eotToken);
    }
    if (encoded.length > contextLength) {
      encoded.removeRange(contextLength, encoded.length);
      encoded[contextLength - 1] = _eotToken;
    }

    final tensor = _tensor(contextLength, 1, 1, 2);
    for (int i = 0; i < encoded.length; i++) {
      tensor.data[i] = encoded[i].toDouble();
    }
    return tensor;
  }

  double _sigmoid(double x) {
    return 1.0 / (1.0 + exp(-x));
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
