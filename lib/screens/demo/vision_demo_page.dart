import 'dart:io';
import 'dart:ui' as ui;

import 'package:ailia/ailia_license.dart';
import 'package:ailia/ailia_model.dart' show AiliaDetectorObject;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../../backend_state.dart';
import '../../background_removal/u2net/u2net.dart';
import '../../image_classification/image_classification_sample.dart';
import '../../image_segmentation/segment-anything-2/segment_image.dart';
import '../../image_segmentation/segment-anything-3.1/segment_anything_3_1.dart';
import '../../model_catalog.dart';
import '../../object_detection/detic.dart';
import '../../object_detection/yolox.dart';
import '../../object_tracking/bytetrack.dart';
import '../../pose_estimation/lw_human_pose.dart';
import '../../utils/image_util.dart';
import 'camera_input.dart';
import 'demo_session.dart';
import 'still_image.dart';

/// Image model demos (object detection, image classification,
/// background removal and segmentation). With the sample image the Run
/// button performs a one-shot inference; with the camera it toggles
/// realtime inference over live frames.
class VisionDemoPage extends StatefulWidget {
  const VisionDemoPage({super.key, required this.model});

  final ModelInfo model;

  @override
  State<VisionDemoPage> createState() => _VisionDemoPageState();
}

class _VisionDemoPageState extends State<VisionDemoPage>
    with SafeSetStateMixin {
  final DemoSession _session = DemoSession();
  final CameraInput _camera = CameraInput();

  bool _useCamera = false;
  ui.Image? _image;

  // Realtime camera inference state.
  bool _realtimeActive = false;
  List<AiliaDetectorObject> _rtBoxes = [];
  List<String> _rtCategories = const [];
  List<TrackedBox> _rtTracked = [];
  List<SkeletonLine> _rtSkeletonLines = [];
  List<Offset> _rtSkeletonPoints = [];
  ui.Image? _rtOverlayImage;
  // The exact camera frame the current results were computed on. Shown
  // instead of the live preview so results never lag behind the video.
  ui.Image? _rtFrameImage;
  String _rtLabel = '';

  // Completion times of recent frames, for the FPS shown at the top
  // right of the preview.
  final List<int> _fpsTimes = [];
  double _fps = 0;

  // SAM2 segmentation point (normalized 0..1); movable by tapping the
  // image or the camera preview.
  Offset _sam2Point = const Offset(0.5, 0.5);
  // Kept open after a still-image run so taps only re-run the prompt
  // encoder + mask decoder on the cached image features.
  SegmentImage? _sam2Still;
  img.Image? _sam2StillInput;
  bool _sam2Busy = false;

  bool get _isSam2 => widget.model.id == 'sam2';

  // SAM 3.1 segments instances matching a text prompt. Both sources
  // run one-shot (the multi-GB encoder is too slow for a realtime
  // loop). After a still-image run the model is kept open with the
  // encoded features (encoder released), so a new prompt only re-runs
  // the grounding model; in camera mode every run grabs a fresh frame,
  // so both models stay open.
  bool get _isSam3 => widget.model.id == 'sam3.1';
  final TextEditingController _sam3Text = TextEditingController();
  SegmentAnything3? _sam3Still;
  SegmentAnything3? _sam3Camera;

  // Detic's recognition resolution is selectable (SwinB is heavy, so
  // the lower resolution trades accuracy for speed).
  bool get _isDetic => widget.model.id == 'detic';
  int _deticWidth = 640;

  // Still-image model instances, kept open across Runs so a repeated
  // Run does not reload the model (on NPU backends the first inference
  // also compiles the graph, so reopening every Run is expensive).
  // Released when leaving the page, switching between Image and Web
  // Camera, or changing the backend in the top bar.
  ObjectDetectionYoloX? _yoloxStill;
  U2Net? _u2netStill;
  ImageClassifier? _classifierStill;
  ObjectTrackingByteTrack? _bytetrackStill;
  Detic? _deticStill;
  PoseEstimationLwHumanPose? _poseStill;

  /// The classifier for the current model (ResNet50 or ViT).
  ImageClassifier _createClassifier() => widget.model.id == 'vit'
      ? ImageClassificationViT()
      : ImageClassificationResNet50();

  @override
  void initState() {
    super.initState();
    _sam3Text.text = widget.model.defaultInputText ?? '';
    BackendState.instance.selectedEnvId.addListener(_onEnvChanged);
    _loadSampleImage();
  }

  @override
  void dispose() {
    _realtimeActive = false;
    BackendState.instance.selectedEnvId.removeListener(_onEnvChanged);
    _releaseStillModels();
    _sam2Still?.close();
    _sam2Still = null;
    _resetSam3Session();
    _sam3Text.dispose();
    _camera.dispose();
    _session.dispose();
    super.dispose();
  }

  /// The cached instances were opened with the previous backend, so a
  /// backend change invalidates them; the next Run reopens the model.
  void _onEnvChanged() {
    _releaseStillModels();
    _resetSam2Session();
    _resetSam3Session();
  }

  void _releaseStillModels() {
    _yoloxStill?.close();
    _yoloxStill = null;
    _u2netStill?.close();
    _u2netStill = null;
    _classifierStill?.close();
    _classifierStill = null;
    _bytetrackStill?.close();
    _bytetrackStill = null;
    _deticStill?.close();
    _deticStill = null;
    _poseStill?.close();
    _poseStill = null;
  }

  /// Shows the bundled sample image before the first run.
  Future<void> _loadSampleImage() async {
    final data = await rootBundle.load(widget.model.sampleAsset!);
    final loaded = await decodeImageFromList(data.buffer.asUint8List());
    safeSetState(() {
      _image = loaded;
    });
  }

  void _resetSam2Session() {
    _sam2Still?.close();
    _sam2Still = null;
    _sam2StillInput = null;
    _sam2Point = const Offset(0.5, 0.5);
  }

  void _resetSam3Session() {
    _sam3Still?.close();
    _sam3Still = null;
    _sam3Camera?.close();
    _sam3Camera = null;
  }

  void _clearRealtimeResults() {
    _rtBoxes = [];
    _rtTracked = [];
    _rtSkeletonLines = [];
    _rtSkeletonPoints = [];
    _rtOverlayImage = null;
    _rtFrameImage = null;
    _rtLabel = '';
    _fpsTimes.clear();
    _fps = 0;
  }

  /// Updates the FPS over a sliding window of recent frames.
  void _tickFps() {
    final now = DateTime.now().millisecondsSinceEpoch;
    _fpsTimes.add(now);
    while (_fpsTimes.length > 30 || now - _fpsTimes.first > 3000) {
      _fpsTimes.removeAt(0);
    }
    if (_fpsTimes.length >= 2) {
      _fps = (_fpsTimes.length - 1) * 1000 / (_fpsTimes.last - _fpsTimes.first);
      safeSetState(() {});
    }
  }

  Future<void> _switchSource(bool useCamera) async {
    if (useCamera) {
      _resetSam2Session();
      _resetSam3Session();
      _releaseStillModels();
      safeSetState(() {
        _useCamera = true;
        _image = null;
        _clearRealtimeResults();
      });
      await _camera.open();
    } else {
      _realtimeActive = false;
      _resetSam2Session();
      _resetSam3Session();
      _releaseStillModels();
      await _camera.close();
      safeSetState(() {
        _useCamera = false;
        _clearRealtimeResults();
      });
      _loadSampleImage();
    }
  }

  // ---------------------------------------------------------------------
  // Still image inference
  // ---------------------------------------------------------------------

  Future<void> _run() => _session.run(() async {
        switch (widget.model.id) {
          case "sam2":
            await _runSam2Still();
            break;
          case "sam3.1":
            await _runSam3Still();
            break;
          case "u2net":
            await _runU2NetStill();
            break;
          case "resnet50":
          case "vit":
            await _runClassifierStill();
            break;
          case "yolox":
            await _runYoloXStill();
            break;
          case "detic":
            await _runDeticStill();
            break;
          case "bytetrack":
            await _runByteTrackStill();
            break;
          case "lw-human-pose":
            await _runLwPoseStill();
            break;
        }
      });

  Future<void> _runSam2Still() async {
    // The sample image never changes, so a repeated Run reuses the
    // open model and the cached image features.
    if (_sam2Still != null) {
      await _runSam2AtPoint(_sam2Point);
      return;
    }

    await _loadSampleImage();

    final files = await _session.downloadModelFiles(imageModelFiles['sam2']!);
    if (files == null) {
      return;
    }

    final segmentImage = SegmentImage();
    segmentImage.open(files[0].path, files[1].path, files[2].path,
        envId: selectedEnvId);

    _session.setStatus("Encoding image...");
    // Let the status render before the encoder blocks the UI isolate.
    await Future.delayed(const Duration(milliseconds: 50));
    final inputImage = await uiImageToImage(_image!);
    try {
      await segmentImage.setImage(inputImage);
    } catch (e) {
      segmentImage.close();
      _session.showError(e);
      return;
    }
    if (!mounted) {
      segmentImage.close();
      return;
    }
    // Keep the model open with the encoded features so taps on the
    // image only re-run the mask decoder.
    _sam2Still = segmentImage;
    _sam2StillInput = inputImage;
    _session.clearStatus();

    // The default point matches the bundled truck image; tap to move it.
    await _runSam2AtPoint(Offset(
      (500 / inputImage.width).clamp(0.0, 1.0),
      (375 / inputImage.height).clamp(0.0, 1.0),
    ));
  }

  /// Segments at [point] (normalized) using the cached image features:
  /// only the prompt encoder and mask decoder run.
  Future<void> _runSam2AtPoint(Offset point) async {
    final seg = _sam2Still;
    final input = _sam2StillInput;
    if (seg == null || input == null || _sam2Busy) {
      return;
    }
    _sam2Busy = true;
    try {
      safeSetState(() {
        _sam2Point = point;
      });
      int startTime = DateTime.now().millisecondsSinceEpoch;
      final maskImage = seg.run([
        img.Point(
          (input.width * point.dx).round().clamp(0, input.width - 1),
          (input.height * point.dy).round().clamp(0, input.height - 1),
        )
      ]);
      int endTime = DateTime.now().millisecondsSinceEpoch;
      if (maskImage == null) {
        return;
      }
      // Overlay on a clone: overlayMaskImage writes into the source
      // pixels, and later taps need the pristine input again.
      final result = await seg.overlayMaskImage(input.clone(), maskImage);
      final maskUiImage = await imageToUiImage(result);
      safeSetState(() {
        _image = maskUiImage;
      });
      _session.showResult("mask decoder : ${endTime - startTime} ms");
    } finally {
      _sam2Busy = false;
    }
  }

  /// Opens SAM 3.1 after downloading its model files, or returns null
  /// (with the error shown) when the download fails.
  Future<SegmentAnything3?> _openSam3() async {
    final files =
        await _session.downloadModelFiles(imageModelFiles['sam3.1']!);
    if (files == null) {
      return null;
    }
    final sam3 = SegmentAnything3();
    sam3.open(files[0].path, files[1].path, envId: selectedEnvId);
    return sam3;
  }

  /// Runs the grounding model of [sam3] (the image must already be
  /// encoded) and shows the detected instances.
  Future<void> _runSam3Grounding(SegmentAnything3 sam3, String text,
      {ui.Image? frameImage, String encodeProfile = ''}) async {
    _session.setStatus("Running grounding...");
    // Let the status render before the inference blocks the UI isolate.
    await Future.delayed(const Duration(milliseconds: 50));
    int startTime = DateTime.now().millisecondsSinceEpoch;
    final result = sam3.run(text);
    int endTime = DateTime.now().millisecondsSinceEpoch;

    final overlay = result.maskOverlay == null
        ? null
        : await imageToUiImage(result.maskOverlay!);
    if (!mounted) {
      return;
    }
    _session.clearStatus();
    safeSetState(() {
      _rtBoxes = result.boxes;
      _rtCategories = List.filled(result.boxes.length, text);
      _rtOverlayImage = overlay;
      if (frameImage != null) {
        _rtFrameImage = frameImage;
      }
    });

    String resultSubText = result.boxes
        .map((e) => "$text ${(e.prob * 100).toStringAsFixed(0)}%")
        .join("\n");
    String profileText =
        "${encodeProfile}grounding : ${endTime - startTime} ms";
    _session.showResult(
        "${result.boxes.length} instances\n$resultSubText\n$profileText");
  }

  /// Runs SAM 3.1 on the sample image with the current text prompt.
  /// The first run downloads the models and encodes the image; later
  /// runs reuse the cached image features and only re-run the
  /// grounding model with the new prompt.
  Future<void> _runSam3Still() async {
    final text = _sam3Text.text.trim();
    if (text.isEmpty) {
      _session.showResult('Enter a text prompt.');
      return;
    }

    if (_sam3Still == null) {
      await _loadSampleImage();

      final sam3 = await _openSam3();
      if (sam3 == null) {
        return;
      }

      _session.setStatus("Encoding image...");
      // Let the status render before the encoder blocks the UI isolate.
      await Future.delayed(const Duration(milliseconds: 50));
      final inputImage = await uiImageToImage(_image!);
      try {
        await sam3.setImage(inputImage);
      } catch (e) {
        sam3.close();
        _session.showError(e);
        return;
      }
      if (!mounted) {
        sam3.close();
        return;
      }
      // The features are cached, so the multi-GB encoder can be freed;
      // new prompts only need the grounding model.
      sam3.releaseEncoder();
      _sam3Still = sam3;
    }

    try {
      await _runSam3Grounding(_sam3Still!, text);
    } catch (e) {
      _session.showError(e);
    }
  }

  /// One-shot SAM 3.1 on the camera: grabs the current frame, encodes
  /// it and segments with the current text prompt. The models stay
  /// open between runs (every run brings a new frame, so unlike the
  /// still path the encoder cannot be released).
  Future<void> _runSam3Camera() => _session.run(() async {
        final text = _sam3Text.text.trim();
        if (text.isEmpty) {
          _session.showResult('Enter a text prompt.');
          return;
        }

        _sam3Camera ??= await _openSam3();
        final sam3 = _sam3Camera;
        if (sam3 == null) {
          return;
        }

        _session.setStatus("Capturing frame...");
        final frame = await _grabOneFrame();
        if (frame == null) {
          throw Exception(_camera.error ?? 'Failed to capture a frame.');
        }
        final frameImage = await frame.toUiImage();

        _session.setStatus("Encoding image...");
        await Future.delayed(const Duration(milliseconds: 50));
        int startTime = DateTime.now().millisecondsSinceEpoch;
        await sam3.setImage(frame.toImage());
        int endTime = DateTime.now().millisecondsSinceEpoch;

        if (!mounted) {
          return;
        }
        await _runSam3Grounding(sam3, text,
            frameImage: frameImage,
            encodeProfile:
                "image encoder : ${endTime - startTime} ms\n");
      });

  /// Grabs a single camera frame via the frame stream (still captures
  /// would fire the shutter sound on mobile).
  Future<CameraFrame?> _grabOneFrame() async {
    await _camera.startFrameStream();
    try {
      // The first frame may take a moment to arrive.
      for (int i = 0; i < 100; i++) {
        final frame = await _camera.grabFrame();
        if (frame != null) {
          return frame;
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }
      return null;
    } finally {
      await _camera.stopFrameStream();
    }
  }

  Future<void> _runU2NetStill() async {
    await _loadSampleImage();

    if (_u2netStill == null) {
      final files =
          await _session.downloadModelFiles(imageModelFiles['u2net']!);
      if (files == null) {
        return;
      }
      final u2net = U2Net();
      u2net.open(files[0].path, envId: selectedEnvId);
      _u2netStill = u2net;
    }
    final u2net = _u2netStill!;

    try {
      final inputImage = await uiImageToImage(_image!);
      int startTime = DateTime.now().millisecondsSinceEpoch;
      await u2net.setImage(inputImage);
      final maskImage = u2net.run();
      int endTime = DateTime.now().millisecondsSinceEpoch;

      if (maskImage == null) {
        return;
      }

      final maskUiImage = await imageToUiImage(maskImage);
      safeSetState(() {
        _image = maskUiImage;
      });
      _session.showResult(
          "processing time : ${endTime - startTime} ms");
    } catch (e) {
      // A failed run may leave the model in a bad state; reopen next Run.
      _u2netStill?.close();
      _u2netStill = null;
      rethrow;
    }
  }

  Future<void> _runClassifierStill() async {
    await _loadSampleImage();

    if (_classifierStill == null) {
      final files = await _session
          .downloadModelFiles(imageModelFiles[widget.model.id]!);
      if (files == null) {
        return;
      }
      final classifier = _createClassifier();
      classifier.open(files[0], selectedEnvId);
      _classifierStill = classifier;
    }
    final classifier = _classifierStill!;
    try {
      int startTime = DateTime.now().millisecondsSinceEpoch;
      String classificationText =
          await classifier.run(await uiImageToImage(_image!));
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${endTime - startTime} ms";

      _session.showResult("$classificationText\n$profileText");
    } catch (e) {
      _classifierStill?.close();
      _classifierStill = null;
      rethrow;
    }
  }

  Future<void> _runYoloXStill() async {
    final data = await rootBundle.load(widget.model.sampleAsset!);
    final imData = data.buffer.asUint8List();
    final loaded = await decodeImageFromList(imData);
    safeSetState(() {
      _image = loaded;
    });

    if (_yoloxStill == null) {
      final files =
          await _session.downloadModelFiles(imageModelFiles['yolox']!);
      if (files == null) {
        return;
      }
      final yolox = ObjectDetectionYoloX();
      yolox.open(files[0], selectedEnvId);
      _yoloxStill = yolox;
    }
    final yolox = _yoloxStill!;
    try {
      final decoded = img.decodeImage(imData)!;
      final width = decoded.width;
      final height = decoded.height;
      final imageWithoutAlpha = decoded.convert(numChannels: 3);
      final buffer = imageWithoutAlpha.getBytes(order: img.ChannelOrder.rgb);

      int startTime = DateTime.now().millisecondsSinceEpoch;
      final res = yolox.run(buffer, width, height);
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${endTime - startTime} ms";

      String resultSubText = res
          .map((e) =>
              "x:${e.x} y:${e.y} w:${e.w} h:${e.h} p:${e.prob} label:${yolox.category[e.category]}")
          .join("\n");

      safeSetState(() {
        _rtBoxes = res;
        _rtCategories = yolox.category;
      });
      _session.showResult("$resultSubText\n$profileText");
    } catch (e) {
      _yoloxStill?.close();
      _yoloxStill = null;
      rethrow;
    }
  }

  // Minimum keypoint score to draw, as in the Kotlin sample.
  static const double _poseScoreThreshold = 0.3;

  /// A distinct color per keypoint index (hue mapped over the range).
  static Color _poseLineColor(int keypointIndex) => HSVColor.fromAHSV(
          1,
          keypointIndex * 360 / PoseEstimationLwHumanPose.keypointCount,
          1,
          1)
      .toColor();

  /// Converts pose results into normalized skeleton drawing data,
  /// skipping segments whose endpoints fall below the score threshold.
  (List<SkeletonLine>, List<Offset>) _toSkeletonDrawing(
      List<PoseObject> poses) {
    final lines = <SkeletonLine>[];
    final points = <Offset>[];
    for (final pose in poses) {
      for (final (a, b) in poseLinePairs) {
        final ka = pose.keypoints[a];
        final kb = pose.keypoints[b];
        if (ka.score < _poseScoreThreshold ||
            kb.score < _poseScoreThreshold) {
          continue;
        }
        lines.add(SkeletonLine(
            Offset(ka.x, ka.y), Offset(kb.x, kb.y), _poseLineColor(a)));
      }
      for (final keypoint in pose.keypoints) {
        if (keypoint.score >= _poseScoreThreshold) {
          points.add(Offset(keypoint.x, keypoint.y));
        }
      }
    }
    return (lines, points);
  }

  /// Repacks tightly packed RGB bytes as RGBA for the pose estimator,
  /// which takes 32bpp input.
  Uint8List _rgbToRgba(Uint8List rgb) {
    final out = Uint8List((rgb.length ~/ 3) * 4);
    int o = 0;
    for (int i = 0; i < rgb.length; i += 3) {
      out[o] = rgb[i];
      out[o + 1] = rgb[i + 1];
      out[o + 2] = rgb[i + 2];
      out[o + 3] = 255;
      o += 4;
    }
    return out;
  }

  Future<void> _runLwPoseStill() async {
    await _loadSampleImage();

    if (_poseStill == null) {
      final files = await _session
          .downloadModelFiles(imageModelFiles['lw-human-pose']!);
      if (files == null) {
        return;
      }
      final pose = PoseEstimationLwHumanPose();
      pose.open(files[0], selectedEnvId);
      _poseStill = pose;
    }
    final pose = _poseStill!;
    try {
      final inputImage = await uiImageToImage(_image!);
      final rgba = inputImage.getBytes(order: img.ChannelOrder.rgba);

      int startTime = DateTime.now().millisecondsSinceEpoch;
      final poses = pose.run(rgba, inputImage.width, inputImage.height);
      int endTime = DateTime.now().millisecondsSinceEpoch;

      final (lines, points) = _toSkeletonDrawing(poses);
      safeSetState(() {
        _rtSkeletonLines = lines;
        _rtSkeletonPoints = points;
      });
      _session.showResult(
          "${poses.length} people\nprocessing time : ${endTime - startTime} ms");
    } catch (e) {
      _poseStill?.close();
      _poseStill = null;
      rethrow;
    }
  }

  Future<void> _realtimeLwPose() async {
    final pose = PoseEstimationLwHumanPose();
    await _runRealtimeModel(
      models: imageModelFiles['lw-human-pose']!,
      openModel: (files) => pose.open(files[0], selectedEnvId),
      closeModel: pose.close,
      onFrame: (frame) async {
        int startTime = DateTime.now().millisecondsSinceEpoch;
        final poses =
            pose.run(_rgbToRgba(frame.rgb), frame.width, frame.height);
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (!mounted) {
          return;
        }
        final frameImage = await frame.toUiImage();
        if (!mounted) {
          return;
        }
        final (lines, points) = _toSkeletonDrawing(poses);
        safeSetState(() {
          _rtSkeletonLines = lines;
          _rtSkeletonPoints = points;
          _rtFrameImage = frameImage;
        });
        _session.showResult(
            "${poses.length} people / ${endTime - startTime} ms per frame");
      },
    );
  }

  /// A distinct color per tracking ID (golden-angle hue steps keep
  /// consecutive IDs visually far apart).
  static Color _trackColor(int id) =>
      HSVColor.fromAHSV(1, (id * 137.508) % 360, 1, 1).toColor();

  List<TrackedBox> _toTrackedBoxes(
      List<ByteTrackResult> results, List<String> categories) {
    return results.map((r) {
      final obj = r.object;
      final name = obj.category < categories.length
          ? categories[obj.category]
          : '${obj.category}';
      return TrackedBox(
        rect: Rect.fromLTWH(obj.x, obj.y, obj.w, obj.h),
        color: _trackColor(obj.id),
        label: '$name ${(obj.prob * 100).toStringAsFixed(0)}% id:${obj.id}',
        trail: r.trail,
      );
    }).toList();
  }

  Future<void> _runByteTrackStill() async {
    final data = await rootBundle.load(widget.model.sampleAsset!);
    final imData = data.buffer.asUint8List();
    final loaded = await decodeImageFromList(imData);
    safeSetState(() {
      _image = loaded;
    });

    if (_bytetrackStill == null) {
      final files =
          await _session.downloadModelFiles(imageModelFiles['bytetrack']!);
      if (files == null) {
        return;
      }
      final tracker = ObjectTrackingByteTrack();
      tracker.open(files[0], selectedEnvId);
      _bytetrackStill = tracker;
    }
    final tracker = _bytetrackStill!;
    try {
      final decoded = img.decodeImage(imData)!;
      final imageWithoutAlpha = decoded.convert(numChannels: 3);
      final buffer = imageWithoutAlpha.getBytes(order: img.ChannelOrder.rgb);

      int startTime = DateTime.now().millisecondsSinceEpoch;
      final res = tracker.run(buffer, decoded.width, decoded.height);
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${endTime - startTime} ms";

      String resultSubText = res
          .map((r) =>
              "id:${r.object.id} label:${tracker.category[r.object.category]} p:${r.object.prob}")
          .join("\n");

      safeSetState(() {
        _rtTracked = _toTrackedBoxes(res, tracker.category);
      });
      _session.showResult("$resultSubText\n$profileText");
    } catch (e) {
      _bytetrackStill?.close();
      _bytetrackStill = null;
      rethrow;
    }
  }

  Future<void> _runDeticStill() async {
    await _loadSampleImage();

    // Keeping the SwinB model resident is heavy on mobile memory, but
    // reloading it on every Run is far slower; it is released when the
    // source is switched or the page is left.
    if (_deticStill == null) {
      final files =
          await _session.downloadModelFiles(imageModelFiles['detic']!);
      if (files == null) {
        return;
      }
      final detic = Detic();
      detic.open(files[0].path, envId: selectedEnvId);
      _deticStill = detic;
    }
    final detic = _deticStill!;
    try {
      _session.setStatus("Running Detic ($_deticWidth px)...");
      // Let the status render before the inference blocks the UI isolate.
      await Future.delayed(const Duration(milliseconds: 50));
      final inputImage = await uiImageToImage(_image!);

      int startTime = DateTime.now().millisecondsSinceEpoch;
      final result = detic.run(inputImage, _deticWidth);
      int endTime = DateTime.now().millisecondsSinceEpoch;

      final overlay = result.maskOverlay == null
          ? null
          : await imageToUiImage(result.maskOverlay!);
      if (!mounted) {
        return;
      }
      _session.clearStatus();
      safeSetState(() {
        _rtBoxes = result.boxes;
        _rtCategories = detic.category;
        _rtOverlayImage = overlay;
      });

      String resultSubText = result.boxes
          .map((e) =>
              "${detic.category[e.category]} ${(e.prob * 100).toStringAsFixed(0)}%")
          .join("\n");
      String profileText =
          "processing time : ${endTime - startTime} ms";
      _session.showResult(
          "${result.boxes.length} instances\n$resultSubText\n$profileText");
    } catch (e) {
      _deticStill?.close();
      _deticStill = null;
      rethrow;
    }
  }

  // ---------------------------------------------------------------------
  // Realtime camera inference
  // ---------------------------------------------------------------------

  Future<void> _toggleRealtime() async {
    if (_realtimeActive) {
      safeSetState(() {
        _realtimeActive = false;
      });
      return;
    }
    if (_camera.usesMacCamera && _camera.macController == null) {
      _session.showError(_camera.error ?? 'Camera is not ready.');
      return;
    }
    safeSetState(() {
      _realtimeActive = true;
      _clearRealtimeResults();
    });
    try {
      await AiliaLicense.checkAndDownloadLicense();
      await _camera.startFrameStream();
      switch (widget.model.id) {
        case "yolox":
          await _realtimeYoloX();
          break;
        case "resnet50":
        case "vit":
          await _realtimeClassifier();
          break;
        case "u2net":
          await _realtimeU2Net();
          break;
        case "sam2":
          await _realtimeSam2();
          break;
        case "detic":
          await _realtimeDetic();
          break;
        case "bytetrack":
          await _realtimeByteTrack();
          break;
        case "lw-human-pose":
          await _realtimeLwPose();
          break;
      }
    } catch (e) {
      _session.showError(e);
    } finally {
      await _camera.stopFrameStream();
      _realtimeActive = false;
      if (mounted) {
        safeSetState(() {});
      }
    }
  }

  /// Runs [onFrame] on every camera frame until realtime mode is
  /// stopped.
  Future<void> _realtimeLoop(
      Future<void> Function(CameraFrame frame) onFrame) async {
    while (_realtimeActive && mounted) {
      final frame = await _camera.grabFrame();
      if (frame == null) {
        await Future.delayed(const Duration(milliseconds: 50));
        continue;
      }
      await onFrame(frame);
      _tickFps();
      // Let the UI breathe between inferences.
      await Future.delayed(const Duration(milliseconds: 16));
    }
  }

  /// Shared skeleton of the realtime demos: download the model files,
  /// open the model, run [onFrame] until stopped, then close.
  Future<void> _runRealtimeModel({
    required List<(String, String)> models,
    required void Function(List<File> files) openModel,
    required Future<void> Function(CameraFrame frame) onFrame,
    required void Function() closeModel,
  }) async {
    final files = await _session.downloadModelFiles(models);
    if (files == null) {
      return;
    }
    openModel(files);
    try {
      await _realtimeLoop(onFrame);
    } finally {
      closeModel();
    }
  }

  Future<void> _realtimeYoloX() async {
    final yolox = ObjectDetectionYoloX();
    await _runRealtimeModel(
      models: imageModelFiles['yolox']!,
      openModel: (files) => yolox.open(files[0], selectedEnvId),
      closeModel: yolox.close,
      onFrame: (frame) async {
        int startTime = DateTime.now().millisecondsSinceEpoch;
        final res = yolox.run(frame.rgb, frame.width, frame.height);
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (!mounted) {
          return;
        }
        final frameImage = await frame.toUiImage();
        if (!mounted) {
          return;
        }
        safeSetState(() {
          _rtBoxes = res;
          _rtCategories = yolox.category;
          _rtFrameImage = frameImage;
        });
        _session.showResult(
            "${res.length} objects / ${endTime - startTime} ms per frame");
      },
    );
  }

  Future<void> _realtimeByteTrack() async {
    final tracker = ObjectTrackingByteTrack();
    await _runRealtimeModel(
      models: imageModelFiles['bytetrack']!,
      openModel: (files) => tracker.open(files[0], selectedEnvId),
      closeModel: tracker.close,
      onFrame: (frame) async {
        int startTime = DateTime.now().millisecondsSinceEpoch;
        final res = tracker.run(frame.rgb, frame.width, frame.height);
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (!mounted) {
          return;
        }
        final frameImage = await frame.toUiImage();
        if (!mounted) {
          return;
        }
        safeSetState(() {
          _rtTracked = _toTrackedBoxes(res, tracker.category);
          _rtFrameImage = frameImage;
        });
        _session.showResult(
            "${res.length} objects / ${endTime - startTime} ms per frame");
      },
    );
  }

  Future<void> _realtimeClassifier() async {
    final classifier = _createClassifier();
    await _runRealtimeModel(
      models: imageModelFiles[widget.model.id]!,
      openModel: (files) => classifier.open(files[0], selectedEnvId),
      closeModel: classifier.close,
      onFrame: (frame) async {
        int startTime = DateTime.now().millisecondsSinceEpoch;
        final label = await classifier.run(frame.toImage());
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (!mounted) {
          return;
        }
        safeSetState(() {
          _rtLabel = label;
        });
        _session.showResult("${endTime - startTime} ms per frame");
      },
    );
  }

  Future<void> _realtimeU2Net() async {
    final u2net = U2Net();
    await _runRealtimeModel(
      models: imageModelFiles['u2net']!,
      openModel: (files) => u2net.open(files[0].path, envId: selectedEnvId),
      closeModel: u2net.close,
      onFrame: (frame) async {
        int startTime = DateTime.now().millisecondsSinceEpoch;
        await u2net.setImage(frame.toImage());
        final maskImage = u2net.run();
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (maskImage == null || !mounted) {
          return;
        }
        final maskUiImage = await imageToUiImage(maskImage);
        final frameImage = await frame.toUiImage();
        if (!mounted) {
          return;
        }
        safeSetState(() {
          // Show the processed frame with its mask so the result never
          // lags behind the live preview.
          _rtFrameImage = frameImage;
          _rtOverlayImage = maskUiImage;
        });
        _session.showResult("${endTime - startTime} ms per frame");
      },
    );
  }

  Future<void> _realtimeSam2() async {
    final segmentImage = SegmentImage();
    await _runRealtimeModel(
      models: imageModelFiles['sam2']!,
      openModel: (files) => segmentImage.open(
          files[0].path, files[1].path, files[2].path,
          envId: selectedEnvId),
      closeModel: segmentImage.close,
      onFrame: (frame) async {
        int startTime = DateTime.now().millisecondsSinceEpoch;
        final inputImage = frame.toImage();
        await segmentImage.setImage(inputImage);
        final p = _sam2Point;
        final point = img.Point(
          (frame.width * p.dx).round().clamp(0, frame.width - 1),
          (frame.height * p.dy).round().clamp(0, frame.height - 1),
        );
        final maskImage = segmentImage.run([point]);
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (maskImage == null || !mounted) {
          return;
        }
        final result =
            await segmentImage.overlayMaskImage(inputImage, maskImage);
        final maskUiImage = await imageToUiImage(result);
        if (!mounted) {
          return;
        }
        safeSetState(() {
          // The result already contains the processed frame, so show it
          // as the full-opacity background.
          _rtFrameImage = maskUiImage;
        });
        _session.showResult("${endTime - startTime} ms per frame");
      },
    );
  }

  Future<void> _realtimeDetic() async {
    final detic = Detic();
    await _runRealtimeModel(
      models: imageModelFiles['detic']!,
      openModel: (files) => detic.open(files[0].path, envId: selectedEnvId),
      closeModel: detic.close,
      onFrame: (frame) async {
        int startTime = DateTime.now().millisecondsSinceEpoch;
        final result = detic.run(frame.toImage(), _deticWidth);
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (!mounted) {
          return;
        }
        final frameImage = await frame.toUiImage();
        final overlay = result.maskOverlay == null
            ? null
            : await imageToUiImage(result.maskOverlay!);
        if (!mounted) {
          return;
        }
        safeSetState(() {
          _rtBoxes = result.boxes;
          _rtCategories = detic.category;
          _rtFrameImage = frameImage;
          _rtOverlayImage = overlay;
        });
        _session.showResult(
            "${result.boxes.length} instances / ${endTime - startTime} ms per frame");
      },
    );
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  Widget _buildSourceSelector() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
                value: false, label: Text('Image'), icon: Icon(Icons.image)),
            ButtonSegment(
                value: true,
                label: Text('Web Camera'),
                icon: Icon(Icons.videocam)),
          ],
          selected: {_useCamera},
          onSelectionChanged: (selection) {
            _switchSource(selection.first);
          },
        ),
        if (_useCamera) ...[
          const SizedBox(width: 12),
          CameraDeviceSelector(
            input: _camera,
            enabled: !_realtimeActive,
            onDeviceChanged: () => safeSetState(_clearRealtimeResults),
          ),
        ],
      ],
    );
  }

  /// Recognition resolution selector for Detic: trade accuracy for
  /// speed by choosing the longest side of the detection input.
  Widget _buildDeticResolutionSelector() {
    return SegmentedButton<int>(
      segments: const [
        ButtonSegment(value: 320, label: Text('320px (fast)')),
        ButtonSegment(value: 640, label: Text('640px (accurate)')),
      ],
      selected: {_deticWidth},
      onSelectionChanged: (selection) {
        safeSetState(() {
          _deticWidth = selection.first;
        });
      },
    );
  }

  Widget _buildImage(BuildContext context) {
    final image = _image;
    if (image == null) {
      return const SizedBox.shrink();
    }
    final samInteractive = _isSam2 && _sam2Still != null;
    return StillImageBox(
      image: image,
      overlay: (_rtBoxes.isNotEmpty ||
              _rtTracked.isNotEmpty ||
              _rtSkeletonLines.isNotEmpty ||
              _rtOverlayImage != null ||
              samInteractive)
          ? CustomPaint(
              painter: CameraOverlayPainter(
                boxes: _rtBoxes,
                categories: _rtCategories,
                trackedBoxes: _rtTracked,
                skeletonLines: _rtSkeletonLines,
                skeletonPoints: _rtSkeletonPoints,
                overlayImage: _rtOverlayImage,
                marker: samInteractive ? _sam2Point : null,
              ),
            )
          : null,
      // Tap to segment at that point using the cached image features.
      onTapNormalized: samInteractive ? _runSam2AtPoint : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DemoPageScaffold(
      model: widget.model,
      session: _session,
      children: [
        if (CameraInput.supported) _buildSourceSelector(),
        if (_isDetic)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _buildDeticResolutionSelector(),
          ),
        if (_isSam3)
          DemoPanel(
            child: TextField(
              controller: _sam3Text,
              decoration: const InputDecoration(
                labelText: 'Text prompt',
                hintText: 'e.g. truck',
                border: OutlineInputBorder(),
              ),
            ),
          ),
        const SizedBox(height: 8),
        if (_useCamera)
          CameraPreviewView(
            input: _camera,
            realtimeActive: _realtimeActive,
            cornerLabel: _realtimeActive && _fps > 0
                ? '${_fps.toStringAsFixed(1)} FPS'
                : null,
            overlay: CustomPaint(
              painter: CameraOverlayPainter(
                boxes: _rtBoxes,
                categories: _rtCategories,
                trackedBoxes: _rtTracked,
                skeletonLines: _rtSkeletonLines,
                skeletonPoints: _rtSkeletonPoints,
                frameImage: _rtFrameImage,
                overlayImage: _rtOverlayImage,
                label: _rtLabel,
                marker: _isSam2 ? _sam2Point : null,
              ),
            ),
            onTapNormalized: _isSam2
                ? (point) => safeSetState(() {
                      _sam2Point = point;
                    })
                : null,
          ),
        _buildImage(context),
        DemoRunButton(
          session: _session,
          stopMode: _realtimeActive,
          // SAM 3.1 is too slow for a realtime loop, so the camera
          // source also runs one-shot on the current frame.
          onPressed: _useCamera
              ? (_isSam3 ? _runSam3Camera : _toggleRealtime)
              : _run,
        ),
      ],
    );
  }
}
