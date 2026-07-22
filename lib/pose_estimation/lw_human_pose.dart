// Lightweight human pose estimation using the ailia SDK Pose
// Estimator API (ported from ailia-models-kotlin's
// AiliaPoseEstimatorSample).

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ailia/ailia.dart' as ailia_dart;
import 'package:ailia/ailia_model.dart';
import 'package:ffi/ffi.dart';

/// One body keypoint in normalized (0..1) image coordinates. A score
/// of 0 means the point was not detected.
class PoseKeypoint {
  const PoseKeypoint({required this.x, required this.y, required this.score});

  final double x;
  final double y;
  final double score;
}

/// One detected person: 19 keypoints (AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_*)
/// and the overall confidence.
class PoseObject {
  const PoseObject({required this.keypoints, required this.totalScore});

  final List<PoseKeypoint> keypoints;
  final double totalScore;
}

/// Keypoint index pairs connected by the skeleton lines.
const List<(int, int)> poseLinePairs = [
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_NOSE,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_SHOULDER_CENTER
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_EYE_LEFT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_NOSE
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_EYE_RIGHT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_NOSE
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_EAR_LEFT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_EYE_LEFT
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_EAR_RIGHT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_EYE_RIGHT
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_SHOULDER_LEFT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_SHOULDER_CENTER
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_SHOULDER_RIGHT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_SHOULDER_CENTER
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_ELBOW_LEFT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_SHOULDER_LEFT
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_ELBOW_RIGHT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_SHOULDER_RIGHT
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_WRIST_LEFT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_ELBOW_LEFT
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_WRIST_RIGHT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_ELBOW_RIGHT
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_BODY_CENTER,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_SHOULDER_CENTER
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_HIP_LEFT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_BODY_CENTER
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_HIP_RIGHT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_BODY_CENTER
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_KNEE_LEFT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_HIP_LEFT
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_KNEE_RIGHT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_HIP_RIGHT
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_ANKLE_LEFT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_KNEE_LEFT
  ),
  (
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_ANKLE_RIGHT,
    ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_KNEE_RIGHT
  ),
];

/// The Pose Estimator API lives in a separate shared library on
/// desktop platforms (ailia_pose_estimate, which links against the
/// main ailia library); Android bundles it into libailia.so and iOS
/// links it into the process.
DynamicLibrary _poseEstimateLibrary() {
  if (Platform.isIOS) {
    return DynamicLibrary.process();
  }
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libailia.so');
  }
  if (Platform.isMacOS) {
    return DynamicLibrary.open('libailia_pose_estimate.dylib');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('ailia_pose_estimate.dll');
  }
  return DynamicLibrary.open('libailia_pose_estimate.so');
}

class PoseEstimationLwHumanPose {
  AiliaModel? _model;
  // FFI bindings resolved against the pose estimate library (see
  // _poseEstimateLibrary); the network itself comes from _model.
  dynamic _poseFfi;
  Pointer<Pointer<ailia_dart.AILIAPoseEstimator>>? _ppEstimator;
  bool available = false;

  static const int keypointCount =
      ailia_dart.AILIA_POSE_ESTIMATOR_POSE_KEYPOINT_CNT;

  void open(File onnxFile, int envId) {
    close();

    final model = AiliaModel();
    model.openFile(onnxFile.path, envId: envId);
    _model = model;
    _poseFfi = ailia_dart.ailiaFFI(_poseEstimateLibrary());

    _ppEstimator = malloc<Pointer<ailia_dart.AILIAPoseEstimator>>();
    int status = _poseFfi.ailiaCreatePoseEstimator(
      _ppEstimator!,
      model.ppAilia!.value,
      ailia_dart.AILIA_POSE_ESTIMATOR_ALGORITHM_LW_HUMAN_POSE,
    );
    if (status != ailia_dart.AILIA_STATUS_SUCCESS) {
      malloc.free(_ppEstimator!);
      _ppEstimator = null;
      model.close();
      _model = null;
      throw Exception("ailiaCreatePoseEstimator failed $status");
    }

    available = true;
  }

  void close() {
    if (!available) {
      return;
    }

    _poseFfi.ailiaDestroyPoseEstimator(_ppEstimator!.value);
    malloc.free(_ppEstimator!);
    _ppEstimator = null;
    _model!.close();
    _model = null;

    available = false;
  }

  /// Runs pose estimation on tightly packed RGBA pixels.
  List<PoseObject> run(Uint8List rgba, int imageWidth, int imageHeight) {
    if (!available) {
      throw Exception("Model not opened");
    }
    if (rgba.length != imageWidth * imageHeight * 4) {
      throw Exception("invalid image format");
    }

    final ailia = _poseFfi;
    final estimator = _ppEstimator!.value;

    final inputData = malloc<Uint8>(rgba.length);
    inputData.asTypedList(rgba.length).setAll(0, rgba);
    int status = ailia.ailiaPoseEstimatorCompute(
      estimator,
      inputData.cast<Void>(),
      imageWidth * 4,
      imageWidth,
      imageHeight,
      ailia_dart.AILIA_IMAGE_FORMAT_RGBA,
    );
    malloc.free(inputData);
    if (status != ailia_dart.AILIA_STATUS_SUCCESS) {
      throw Exception("ailiaPoseEstimatorCompute failed $status");
    }

    final count = malloc<Uint32>();
    count.value = 0;
    status = ailia.ailiaPoseEstimatorGetObjectCount(estimator, count);
    if (status != ailia_dart.AILIA_STATUS_SUCCESS) {
      malloc.free(count);
      throw Exception("ailiaPoseEstimatorGetObjectCount failed $status");
    }
    final objectCount = count.value;
    malloc.free(count);

    final poses = <PoseObject>[];
    for (int idx = 0; idx < objectCount; idx++) {
      final pObj = malloc<ailia_dart.AILIAPoseEstimatorObjectPose>();
      status = ailia.ailiaPoseEstimatorGetObjectPose(
        estimator,
        pObj,
        idx,
        ailia_dart.AILIA_POSE_ESTIMATOR_OBJECT_POSE_VERSION,
      );
      if (status != ailia_dart.AILIA_STATUS_SUCCESS) {
        malloc.free(pObj);
        throw Exception("ailiaPoseEstimatorGetObjectPose failed $status");
      }

      final keypoints = <PoseKeypoint>[];
      for (int k = 0; k < keypointCount; k++) {
        final point = pObj.ref.points[k];
        keypoints.add(
            PoseKeypoint(x: point.x, y: point.y, score: point.score));
      }
      poses.add(PoseObject(
          keypoints: keypoints, totalScore: pObj.ref.total_score));

      malloc.free(pObj);
    }

    return poses;
  }
}
