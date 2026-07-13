import 'dart:io';
import 'dart:ui' as ui;

import 'package:ailia/ailia_license.dart';
import 'package:ailia/ailia_model.dart' show AiliaDetectorObject;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../../background_removal/u2net/u2net.dart';
import '../../image_classification/image_classification_sample.dart';
import '../../image_segmentation/segment-anything-2/segment_image.dart';
import '../../model_catalog.dart';
import '../../object_detection/yolox.dart';
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
  ui.Image? _rtOverlayImage;
  // The exact camera frame the current results were computed on. Shown
  // instead of the live preview so results never lag behind the video.
  ui.Image? _rtFrameImage;
  String _rtLabel = '';

  // SAM2 segmentation point (normalized 0..1); movable by tapping the
  // image or the camera preview.
  Offset _sam2Point = const Offset(0.5, 0.5);
  // Kept open after a still-image run so taps only re-run the prompt
  // encoder + mask decoder on the cached image features.
  SegmentImage? _sam2Still;
  img.Image? _sam2StillInput;
  bool _sam2Busy = false;

  bool get _isSam2 => widget.model.id == 'sam2';

  @override
  void initState() {
    super.initState();
    _loadSampleImage();
  }

  @override
  void dispose() {
    _realtimeActive = false;
    _sam2Still?.close();
    _sam2Still = null;
    _camera.dispose();
    _session.dispose();
    super.dispose();
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

  void _clearRealtimeResults() {
    _rtBoxes = [];
    _rtOverlayImage = null;
    _rtFrameImage = null;
    _rtLabel = '';
  }

  Future<void> _switchSource(bool useCamera) async {
    if (useCamera) {
      _resetSam2Session();
      safeSetState(() {
        _useCamera = true;
        _image = null;
        _clearRealtimeResults();
      });
      await _camera.open();
    } else {
      _realtimeActive = false;
      _resetSam2Session();
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
          case "u2net":
            await _runU2NetStill();
            break;
          case "resnet18":
            await _runResNet18Still();
            break;
          case "yolox":
            await _runYoloXStill();
            break;
        }
      });

  Future<void> _runSam2Still() async {
    _sam2Still?.close();
    _sam2Still = null;
    _sam2StillInput = null;

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
      _session.showResult("mask decoder : ${(endTime - startTime) / 1000} sec");
    } finally {
      _sam2Busy = false;
    }
  }

  Future<void> _runU2NetStill() async {
    await _loadSampleImage();

    final files = await _session.downloadModelFiles(imageModelFiles['u2net']!);
    if (files == null) {
      return;
    }

    U2Net u2net = U2Net();
    u2net.open(files[0].path, envId: selectedEnvId);

    final inputImage = await uiImageToImage(_image!);
    await u2net.setImage(inputImage);

    final maskImage = u2net.run();

    if (maskImage == null) {
      u2net.close();
      return;
    }

    final maskUiImage = await imageToUiImage(maskImage);
    safeSetState(() {
      _image = maskUiImage;
    });
    _session.showResult('Generated masks.');

    u2net.close();
  }

  Future<void> _runResNet18Still() async {
    await _loadSampleImage();

    final files =
        await _session.downloadModelFiles(imageModelFiles['resnet18']!);
    if (files == null) {
      return;
    }
    final classifier = ImageClassificationResNet18();
    classifier.open(files[0], selectedEnvId);
    try {
      int startTime = DateTime.now().millisecondsSinceEpoch;
      String classificationText =
          await classifier.run(await uiImageToImage(_image!));
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      _session.showResult("$classificationText\n$profileText");
    } catch (e) {
      _session.showError(e);
    } finally {
      classifier.close();
    }
  }

  Future<void> _runYoloXStill() async {
    final data = await rootBundle.load(widget.model.sampleAsset!);
    final imData = data.buffer.asUint8List();
    final loaded = await decodeImageFromList(imData);
    safeSetState(() {
      _image = loaded;
    });

    final files = await _session.downloadModelFiles(imageModelFiles['yolox']!);
    if (files == null) {
      return;
    }
    ObjectDetectionYoloX yolox = ObjectDetectionYoloX();
    yolox.open(files[0], selectedEnvId);
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
          "processing time : ${(endTime - startTime) / 1000} sec";

      String resultSubText = res
          .map((e) =>
              "x:${e.x} y:${e.y} w:${e.w} h:${e.h} p:${e.prob} label:${yolox.category[e.category]}")
          .join("\n");

      safeSetState(() {
        _rtBoxes = res;
        _rtCategories = yolox.category;
      });
      _session.showResult("$resultSubText\n$profileText");
    } finally {
      yolox.close();
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
      if (_camera.usesMacCamera) {
        await _camera.startMacStream();
      }
      switch (widget.model.id) {
        case "yolox":
          await _realtimeYoloX();
          break;
        case "resnet18":
          await _realtimeResNet18();
          break;
        case "u2net":
          await _realtimeU2Net();
          break;
        case "sam2":
          await _realtimeSam2();
          break;
      }
    } catch (e) {
      _session.showError(e);
    } finally {
      if (_camera.usesMacCamera) {
        await _camera.stopMacStream();
      }
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

  Future<void> _realtimeResNet18() async {
    final classifier = ImageClassificationResNet18();
    await _runRealtimeModel(
      models: imageModelFiles['resnet18']!,
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

  Widget _buildImage(BuildContext context) {
    final size = stillImageBoxSize(context, _image);
    if (size == null) {
      return const SizedBox.shrink();
    }
    final samInteractive = _isSam2 && _sam2Still != null;
    Widget content = Stack(
      fit: StackFit.expand,
      children: [
        CustomPaint(
          painter: StillImagePainter(image: _image!),
        ),
        if (_rtBoxes.isNotEmpty || samInteractive)
          CustomPaint(
            painter: CameraOverlayPainter(
              boxes: _rtBoxes,
              categories: _rtCategories,
              marker: samInteractive ? _sam2Point : null,
            ),
          ),
      ],
    );
    if (samInteractive) {
      // Tap to segment at that point using the cached image features.
      content = GestureDetector(
        onTapDown: (details) {
          _runSam2AtPoint(Offset(
            (details.localPosition.dx / size.width).clamp(0.0, 1.0),
            (details.localPosition.dy / size.height).clamp(0.0, 1.0),
          ));
        },
        child: content,
      );
    }
    return Container(
      width: size.width,
      height: size.height,
      margin: const EdgeInsets.only(top: 12),
      child: content,
    );
  }

  @override
  Widget build(BuildContext context) {
    return DemoPageScaffold(
      model: widget.model,
      session: _session,
      children: [
        if (CameraInput.supported) _buildSourceSelector(),
        const SizedBox(height: 8),
        if (_useCamera)
          CameraPreviewView(
            input: _camera,
            realtimeActive: _realtimeActive,
            overlay: CustomPaint(
              painter: CameraOverlayPainter(
                boxes: _rtBoxes,
                categories: _rtCategories,
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
          onPressed: _useCamera ? _toggleRealtime : _run,
        ),
      ],
    );
  }
}
