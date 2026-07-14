// ailia SDKとyoloxを使用して入力された画像から物体を取得する

import 'dart:io';
import 'dart:typed_data';
import 'package:ailia/ailia_model.dart';

class ObjectDetectionYoloX {
  bool available = false;
  bool debug = false;
  AiliaDetectorModel? ailiaModelImage;

  List<String> category = [
    "person",
    "bicycle",
    "car",
    "motorcycle",
    "airplane",
    "bus",
    "train",
    "truck",
    "boat",
    "traffic light",
    "fire hydrant",
    "stop sign",
    "parking meter",
    "bench",
    "bird",
    "cat",
    "dog",
    "horse",
    "sheep",
    "cow",
    "elephant",
    "bear",
    "zebra",
    "giraffe",
    "backpack",
    "umbrella",
    "handbag",
    "tie",
    "suitcase",
    "frisbee",
    "skis",
    "snowboard",
    "sports ball",
    "kite",
    "baseball bat",
    "baseball glove",
    "skateboard",
    "surfboard",
    "tennis racket",
    "bottle",
    "wine glass",
    "cup",
    "fork",
    "knife",
    "spoon",
    "bowl",
    "banana",
    "apple",
    "sandwich",
    "orange",
    "broccoli",
    "carrot",
    "hot dog",
    "pizza",
    "donut",
    "cake",
    "chair",
    "couch",
    "potted plant",
    "bed",
    "dining table",
    "toilet",
    "tv",
    "laptop",
    "mouse",
    "remote",
    "keyboard",
    "cell phone",
    "microwave",
    "oven",
    "toaster",
    "sink",
    "refrigerator",
    "book",
    "clock",
    "vase",
    "scissors",
    "teddy bear",
    "hair drier",
    "toothbrush"
  ];

  void open(File imageOnnxFile, int envId) {
    if (available) {
      return;
    }

    close(); // for reopen

    ailiaModelImage = AiliaDetectorModel();
    String onnxPath = imageOnnxFile.path;
    ailiaModelImage!.openFile(onnxPath, envId: envId);

    available = true;
  }

  void close() {
    if (!available) {
      return;
    }

    ailiaModelImage!.close();

    available = false;
  }

  List<AiliaDetectorObject> run(
    Uint8List data,
    int imageWidth,
    int imageHeight, {
    double threshold = 0.4,
    double iou = 0.45,
  }) {
    if (!available) {
      throw ("Model not opened");
    }

    if (debug) {
      print("Resize $imageWidth $imageHeight");
    }

    List<AiliaDetectorObject> ret = ailiaModelImage!
        .run(data, imageWidth, imageHeight, threshold: threshold, iou: iou);
    return ret;
  }
}
