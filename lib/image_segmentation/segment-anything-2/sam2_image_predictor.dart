import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart';

import 'package:ailia/ailia_model.dart';

const imageSize = 1024;

class Sam2ImagePredictor {
  int _inputWidth = 0;
  int _inputHeight = 0;

  Future<List<AiliaTensor>> setImage(
    Image image,
    AiliaModel imageEncoder,
  ) async {
    _inputWidth = image.width;
    _inputHeight = image.height;
    final resizedImage = copyResize(
      image,
      width: imageSize,
      height: imageSize,
      interpolation: Interpolation.linear,
    );
    AiliaTensor inputTensor = await _preprocessImage(resizedImage);

    List<AiliaTensor> output = imageEncoder.run([inputTensor]);
    // final vision_features = output[0];
    // final vision_pos_enc_0 = output[1];
    // final vision_pos_enc_1 = output[2];
    // final vision_pos_enc_2 = output[3];
    final backboneFpn0 = output[4];
    final backboneFpn1 = output[5];
    final backboneFpn2 = output[6];
    // final backbone_out = {
    //   "vision_features": vision_features,
    //   "vision_pos_enc": [vision_pos_enc_0, vision_pos_enc_1, vision_pos_enc_2],
    //   "backbone_fpn": [backbone_fpn_0, backbone_fpn_1, backbone_fpn_2]
    // };
    // final visionFeats =
    //     _prepareBackboneFeatures([backboneFpn0, backboneFpn1, backboneFpn2]);
    final visionFeats = [backboneFpn0, backboneFpn1, backboneFpn2];

    // Add no_mem_embed, which is added to the lowest rest feat. map during training on videos
    AiliaTensor noMemEmbed = _createAiliaTensor(Float32List(256), 1, 1, 256);
    noMemEmbed = _truncNormal(noMemEmbed, std: 0.02);
    visionFeats[visionFeats.length - 1] =
        _plus(visionFeats[visionFeats.length - 1], noMemEmbed);

    if (visionFeats.length != 3) {
      return [];
    }

    return [visionFeats[2], visionFeats[0], visionFeats[1]];

    // const bbFeatSizes = [
    //   [256, 256],
    //   [128, 128],
    //   [64, 64],
    // ];

    // List<AiliaTensor> feats = [];
    // for (int i = 0; i < 3; i++) {
    //   AiliaTensor feat = _transpose(visionFeats[i], 1, 2, 0);
    //   final featSize = bbFeatSizes[i];
    //   int y = feat.data.length ~/ (feat.shape.x * feat.shape.z * feat.shape.w);
    //   feat = _reshape(feat, 1, y, featSize[0], featSize[1]);
    //   feats.add(feat);
    // }

    // //     feats = [
    // //         np.transpose(feat, (1, 2, 0)).reshape(1, -1, *feat_size)
    // //         for feat, feat_size in zip(vision_feats[::-1], bb_feat_sizes[::-1])
    // //     ][::-1]

    // // final features = {
    // //   "image_embed": feats[feats.length - 1],
    // //   "high_res_feats": [feats[0], feats[1]],
    // // };
    // return [feats[feats.length - 1], feats[0], feats[1]];
  }

  Image? predict(
    AiliaTensor imageFeature,
    List<AiliaTensor> highResFeatures,
    List<Point> pointCoords,
    List<int> pointLabels,
    AiliaModel promptEncoder,
    AiliaModel maskDecoder,
  ) {
    if (_inputWidth == 0 || _inputHeight == 0 || pointCoords.isEmpty) {
      return null;
    }

    final promptInputs = _prepPrompts(pointCoords, pointLabels);

    // sparse_embeddings, dense_embeddings, dense_pe = promptEncoder.run({"coords":concat_points[0], "labels":concat_points[1], "masks":mask_input_dummy, "masks_enable":masks_enable})
    final promptOutputs = promptEncoder.run(promptInputs);
    final sparseEmbeddings = promptOutputs[0];
    final denseEmbeddings = promptOutputs[1];
    final densePe = promptOutputs[2];

    final maskInputs = [
      imageFeature,
      densePe,
      sparseEmbeddings,
      denseEmbeddings,
      highResFeatures[0],
      highResFeatures[1]
    ];

    // masks, iou_pred, sam_tokens_out, object_score_logits  = mask_decoder.run({
    //     "image_embeddings":image_feature,
    //     "image_pe": dense_pe,
    //     "sparse_prompt_embeddings": sparse_embeddings,
    //     "dense_prompt_embeddings": dense_embeddings,
    //     "high_res_features1":high_res_features[0],
    //     "high_res_features2":high_res_features[1]})
    final maskOutputs = maskDecoder.run(maskInputs);
    AiliaTensor masks = maskOutputs[0]; // 1, 4, x , y
    AiliaTensor iouPred = maskOutputs[1]; // 1, 4

    int scoreIndex = _getMaxScoreIndex(iouPred);
    AiliaTensor? mask = _getMask(masks, scoreIndex);
    if (mask == null) {
      return null;
    }
    final maskImage = _convertAiliaTensorToImage(mask);
    return copyResize(
      maskImage,
      width: _inputWidth,
      height: _inputHeight,
      interpolation: Interpolation.linear,
    );

    // low_res_masks, iou_predictions, _, _  = self.forward_postprocess(masks, iou_pred, sam_tokens_out, object_score_logits)

    // // # Upscale the masks to the original image resolution
    // masks = self.postprocess_masks(
    //     low_res_masks, orig_hw
    // )
    // low_res_masks = np.clip(low_res_masks, -32.0, 32.0)
    // mask_threshold = 0.0
    // masks = masks > mask_threshold

    // return masks, iou_predictions, low_res_masks
  }

  AiliaTensor? _getMask(AiliaTensor masks, int scoreIndex) {
    int numMasks = masks.shape.y;
    // Skip first and out range
    if (scoreIndex < 1 || scoreIndex >= numMasks) {
      return null;
    }

    int width = masks.shape.x;
    int height = masks.shape.y;
    int length = width * height;
    final result = _createAiliaTensor(
      Float32List(length),
      width,
      height,
      1,
    );

    int offset = length * scoreIndex;
    for (int i = 0; i < length; i++) {
      double value = masks.data[offset + i];
      result.data[i] = value > 0.0 ? 1.0 : 0.0;
    }

    return result;
  }

  int _getMaxScoreIndex(AiliaTensor iouPred) {
    int maxIndex = 0;
    double maxScore = 0.0;
    // Skip first
    for (int i = 1; i < iouPred.data.length; i++) {
      if (iouPred.data[i] > maxScore) {
        maxScore = iouPred.data[i];
        maxIndex = i;
      }
    }
    return maxIndex;
  }

  List<AiliaTensor> _prepPrompts(
      List<Point> pointCoords, List<int> pointLabels) {
    final coords = _transformCoords(pointCoords);
    final labels = _createAiliaTensor(
      Float32List.fromList(pointLabels.map((e) => e.toDouble()).toList()),
      pointLabels.length,
      1,
      1,
      dim: 2,
    );

    // mask input
    List<double> dummy = List.filled(256 * 256, 0.0);
    final maskInput =
        _createAiliaTensor(Float32List.fromList(dummy), 256, 256, 1, dim: 3);
    final masksEnable =
        _createAiliaTensor(Float32List.fromList([0.0]), 1, 1, 1, dim: 1);

    return [coords, labels, maskInput, masksEnable];
  }

  AiliaTensor _transformCoords(List<Point> coords) {
    List<double> points = [];
    for (int i = 0; i < coords.length; i++) {
      double x = coords[i].x / _inputWidth * imageSize;
      double y = coords[i].y / _inputHeight * imageSize;
      points.add(x);
      points.add(y);
    }

    return _createAiliaTensor(Float32List.fromList(points), 2, coords.length, 1,
        dim: 3);
  }

  Future<AiliaTensor> _preprocessImage(Image image) async {
    AiliaTensor inputTensor = _createAiliaTensor(
        Float32List(image.width * image.height * 3),
        image.width,
        image.height,
        3);

    List pixel = image.buffer.asUint8List().toList();
    final numChannels = image.numChannels;

    List mean = [0.485, 0.456, 0.406];
    List std = [0.229, 0.224, 0.225];

    for (int y = 0; y < image.height; y++) {
      for (int x = 0; x < image.width; x++) {
        for (int rgb = 0; rgb < 3; rgb++) {
          inputTensor.data[
                  y * image.width + x + rgb * image.width * image.height] =
              (pixel[(image.width * y + x) * numChannels + rgb] / 255.0 -
                      mean[rgb]) /
                  std[rgb];
        }
      }
    }

    return inputTensor;
  }

  AiliaTensor _generateNormalDistribution(
      AiliaTensor input, double mean, double std) {
    Random random = Random();
    int size = input.shape.x * input.shape.y * input.shape.z;
    List<double> samples = List.filled(size, 0.0);

    for (int i = 0; i < size; i++) {
      double u1 = random.nextDouble();
      double u2 = random.nextDouble();
      double z0 = sqrt(-2.0 * log(u1)) * cos(2.0 * pi * u2);
      samples[i] = z0 * std + mean;
    }
    input.data = Float32List.fromList(samples);

    return input;
  }

  AiliaTensor _clip(AiliaTensor input, double min, double max) {
    int size = input.shape.x * input.shape.y * input.shape.z;

    for (int i = 0; i < size; i++) {
      input.data[i] = input.data[i] < min
          ? min
          : input.data[i] > max
              ? max
              : input.data[i];
    }

    return input;
  }

  AiliaTensor _plus(AiliaTensor a, AiliaTensor b) {
    int x = a.shape.x > b.shape.x ? a.shape.x : b.shape.x;
    int y = a.shape.y > b.shape.y ? a.shape.y : b.shape.y;
    int z = a.shape.z > b.shape.z ? a.shape.z : b.shape.z;

    Float32List result = Float32List(x * y * z);

    for (int i = 0; i < x; i++) {
      for (int j = 0; j < y; j++) {
        for (int k = 0; k < z; k++) {
          double aValue = a.data[(i % a.shape.x) * a.shape.y * a.shape.z +
              (j % a.shape.y) * a.shape.z +
              (k % a.shape.z)];
          double bValue = b.data[(i % b.shape.x) * b.shape.y * b.shape.z +
              (j % b.shape.y) * b.shape.z +
              (k % b.shape.z)];
          result[i * y * z + j * z + k] = aValue + bValue;
        }
      }
    }

    return _createAiliaTensor(Float32List.fromList(result), x, y, z);
  }

  AiliaTensor _truncNormal(AiliaTensor input,
      {double std = 0.02, int a = -2, int b = 2}) {
    final output = _generateNormalDistribution(input, 0.0, std);
    return _clip(output, a * std, b * std);
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

  Image _convertAiliaTensorToImage(AiliaTensor input) {
    final width = input.shape.x;
    final height = input.shape.y;
    final numChannels = input.shape.z;
    final data = input.data;

    final pixels = Uint8List(width * height * 4);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final index = (y * width + x);
        pixels[index * 4 + 3] = (data[index * numChannels] * 255).toInt();
      }
    }

    return Image.fromBytes(
      width: width,
      height: height,
      numChannels: 4,
      bytes: pixels.buffer,
    );
  }
}
