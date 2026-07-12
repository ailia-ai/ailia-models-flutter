import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ailia/ailia_license.dart';
import 'package:ailia/ailia_model.dart' show AiliaDetectorObject;
import 'package:camera/camera.dart';
// AudioFormat collides with mic_stream's; we only use the photo API.
import 'package:camera_macos/camera_macos.dart' hide AudioFormat;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:mic_stream/mic_stream.dart';
import 'package:path/path.dart' show basename;
import 'package:permission_handler/permission_handler.dart';
import 'package:wav/wav.dart';

import 'package:ailia_speech/ailia_speech_model.dart';

import '../audio_processing/whisper.dart';
import '../audio_processing/whisper_streaming.dart';
import '../background_removal/u2net/u2net.dart';
import '../backend_state.dart';
import '../image_classification/image_classification_sample.dart';
import '../image_segmentation/segment-anything-2/segment_image.dart';
import '../large_language_model/large_language_model.dart';
import '../large_language_model/multimodal_large_language_model.dart';
import '../model_catalog.dart';
import '../natural_language_processing/fugumt.dart';
import '../natural_language_processing/multilingual_e5.dart';
import '../object_detection/yolox.dart';
import '../text_to_speech/text_to_speech.dart';
import '../utils/download_model.dart';
import '../utils/image_util.dart';

/// Input source for the demo. Image demos can switch between a sample
/// image and the web camera; audio demos between a sample audio file
/// and the microphone.
enum InputSource { sample, camera, mic }

class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key, required this.model});

  final ModelInfo model;

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  String predict_result = "";
  String mic_volume = "";
  int _runCounter = 0;
  bool _running = false;

  InputSource _inputSource = InputSource.sample;
  bool _virtualMemory = false;

  // Camera state
  CameraController? _cameraController;
  // macOS uses the camera_macos package; the view initializes the controller.
  CameraMacOSController? _macCameraController;
  String? _cameraError;
  Uint8List? _capturedBytes;
  String? _capturedPath;

  // Realtime camera inference state
  bool _realtimeActive = false;
  List<AiliaDetectorObject> _rtBoxes = [];
  List<String> _rtCategories = const [];
  ui.Image? _rtOverlayImage;
  String _rtLabel = '';
  double _cameraAspect = 4 / 3;
  CameraImageData? _macLatestFrame;

  ui.Image? image;
  bool isImageloaded = false;

  int get selectedEnvId => BackendState.instance.selectedEnvId.value;

  // The camera plugin has no macOS/Linux implementation;
  // macOS is covered by the camera_macos package instead.
  bool get _hasCameraPlugin =>
      kIsWeb ||
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isMacOS;

  bool get _usesMacCamera => !kIsWeb && Platform.isMacOS;

  bool get _supportsCamera =>
      _hasCameraPlugin &&
      (widget.model.input == ModelInputKind.image ||
          widget.model.input == ModelInputKind.imageText);

  bool get _supportsMic => widget.model.input == ModelInputKind.audio;

  @override
  void dispose() {
    _realtimeActive = false;
    _cameraController?.dispose();
    _macCameraController?.destroy();
    listener?.cancel();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Input helpers
  // ---------------------------------------------------------------------

  Future<void> _switchInputSource(InputSource source) async {
    if (source == InputSource.camera) {
      setState(() {
        _inputSource = source;
        _cameraError = null;
        _capturedBytes = null;
        _capturedPath = null;
        isImageloaded = false;
      });
      if (_usesMacCamera) {
        // CameraMacOSView initializes the controller itself.
        return;
      }
      try {
        if (_cameraController == null) {
          final cameras = await availableCameras();
          if (cameras.isEmpty) {
            throw Exception('No camera found');
          }
          // Prefer a normal camera over IR/depth cameras (Windows Hello).
          final camera = cameras.firstWhere(
            (c) => !c.name.toUpperCase().contains('IR'),
            orElse: () => cameras.first,
          );
          final controller = CameraController(
            camera,
            ResolutionPreset.medium,
            enableAudio: false,
          );
          await controller.initialize();
          _cameraController = controller;
          _cameraAspect = controller.value.aspectRatio;
        }
      } catch (e) {
        _cameraController = null;
        _cameraError = 'Camera error: $e';
      }
      if (mounted) setState(() {});
    } else {
      _realtimeActive = false;
      final controller = _cameraController;
      _cameraController = null;
      await controller?.dispose();
      final macController = _macCameraController;
      _macCameraController = null;
      _macLatestFrame = null;
      await macController?.destroy();
      setState(() {
        _inputSource = source;
        _capturedBytes = null;
        _capturedPath = null;
        _rtBoxes = [];
        _rtOverlayImage = null;
        _rtLabel = '';
      });
    }
  }

  /// Captures a still image when the web camera is the input source.
  Future<bool> _prepareInput() async {
    _capturedBytes = null;
    _capturedPath = null;
    if (_supportsCamera && _inputSource == InputSource.camera) {
      if (_usesMacCamera) {
        final controller = _macCameraController;
        if (controller == null) {
          setState(() {
            predict_result = _cameraError ?? 'Camera is not ready.';
          });
          return false;
        }
        final shot = await controller.takePicture();
        final bytes = shot?.bytes;
        if (bytes == null) {
          setState(() {
            predict_result = 'Failed to capture image.';
          });
          return false;
        }
        _capturedBytes = bytes;
        // Some demos (multimodal LLM) need a file path.
        final file = File(
            '${Directory.systemTemp.path}/ailia_camera_capture.jpg');
        await file.writeAsBytes(bytes);
        _capturedPath = file.path;
        return true;
      }
      final controller = _cameraController;
      if (controller == null || !controller.value.isInitialized) {
        setState(() {
          predict_result = _cameraError ?? 'Camera is not ready.';
        });
        return false;
      }
      final shot = await controller.takePicture();
      _capturedBytes = await shot.readAsBytes();
      _capturedPath = shot.path;
    }
    return true;
  }

  Future<ui.Image> _loadInputUiImage(String defaultAsset) async {
    if (_capturedBytes != null) {
      return decodeImageFromList(_capturedBytes!);
    }
    ByteData data = await rootBundle.load(defaultAsset);
    return decodeImageFromList(data.buffer.asUint8List());
  }

  Future<Uint8List> _loadInputEncodedBytes(String defaultAsset) async {
    if (_capturedBytes != null) {
      return _capturedBytes!;
    }
    ByteData data = await rootBundle.load(defaultAsset);
    return data.buffer.asUint8List();
  }

  // ---------------------------------------------------------------------
  // Realtime camera inference
  // ---------------------------------------------------------------------

  bool get _supportsRealtime =>
      _inputSource == InputSource.camera &&
      widget.model.input == ModelInputKind.image;

  _CameraFrame _bgraToRgb(CameraImageData data) {
    final out = Uint8List(data.width * data.height * 3);
    int o = 0;
    for (int y = 0; y < data.height; y++) {
      int i = y * data.bytesPerRow;
      for (int x = 0; x < data.width; x++) {
        out[o++] = data.bytes[i + 2];
        out[o++] = data.bytes[i + 1];
        out[o++] = data.bytes[i];
        i += 4;
      }
    }
    return _CameraFrame(out, data.width, data.height);
  }

  /// Grabs the current camera frame as tightly packed RGB bytes.
  Future<_CameraFrame?> _grabCameraFrame() async {
    if (_usesMacCamera) {
      final data = _macLatestFrame;
      if (data == null) {
        return null;
      }
      return _bgraToRgb(data);
    }
    final controller = _cameraController;
    if (controller == null || !controller.value.isInitialized) {
      return null;
    }
    final shot = await controller.takePicture();
    final bytes = await shot.readAsBytes();
    try {
      // Avoid piling up capture files while looping.
      await File(shot.path).delete();
    } catch (_) {}
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return null;
    }
    final rgbImage = decoded.convert(numChannels: 3);
    return _CameraFrame(rgbImage.getBytes(order: img.ChannelOrder.rgb),
        rgbImage.width, rgbImage.height);
  }

  img.Image _frameToImage(_CameraFrame frame) {
    return img.Image.fromBytes(
      width: frame.width,
      height: frame.height,
      bytes: frame.rgb.buffer,
      numChannels: 3,
    );
  }

  void _updateCameraAspect(int width, int height) {
    final aspect = width / height;
    if ((aspect - _cameraAspect).abs() > 0.01 && mounted) {
      setState(() {
        _cameraAspect = aspect;
      });
    }
  }

  Future<void> _toggleRealtime() async {
    if (_realtimeActive) {
      setState(() {
        _realtimeActive = false;
      });
      return;
    }
    if (_usesMacCamera && _macCameraController == null) {
      setState(() {
        predict_result = _cameraError ?? 'Camera is not ready.';
      });
      return;
    }
    setState(() {
      _realtimeActive = true;
      _rtBoxes = [];
      _rtOverlayImage = null;
      _rtLabel = '';
    });
    try {
      await AiliaLicense.checkAndDownloadLicense();
      if (_usesMacCamera) {
        _macLatestFrame = null;
        await _macCameraController!.startImageStream((data) {
          if (data != null) {
            _macLatestFrame = data;
            _updateCameraAspect(data.width, data.height);
          }
        });
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
        default:
          setState(() {
            predict_result = 'Realtime mode is not supported for this model.';
          });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          predict_result = "Error: $e";
        });
      }
    } finally {
      if (_usesMacCamera) {
        try {
          await _macCameraController?.stopImageStream();
        } catch (_) {
          // The controller may already be destroyed.
        }
      }
      _realtimeActive = false;
      if (mounted) {
        setState(() {});
      }
    }
  }

  /// Runs [onFrame] on every camera frame until realtime mode is stopped.
  Future<void> _realtimeLoop(
      Future<void> Function(_CameraFrame frame) onFrame) async {
    while (_realtimeActive && mounted) {
      final frame = await _grabCameraFrame();
      if (frame == null) {
        await Future.delayed(const Duration(milliseconds: 50));
        continue;
      }
      await onFrame(frame);
      // Let the UI breathe between inferences.
      await Future.delayed(const Duration(milliseconds: 16));
    }
  }

  Future<void> _realtimeYoloX() async {
    _displayDownloadBegin();
    final onnxFile = await downloadModel(
        "https://storage.googleapis.com/ailia-models/yolox/yolox_s.opt.onnx",
        "yolox_s.opt.onnx",
        null,
        _displayDownloadProgress);
    await _displayDownloadEnd();
    if (onnxFile == null) {
      return;
    }
    final yolox = ObjectDetectionYoloX();
    yolox.open(onnxFile, selectedEnvId);
    try {
      await _realtimeLoop((frame) async {
        int startTime = DateTime.now().millisecondsSinceEpoch;
        final res = yolox.run(frame.rgb, frame.width, frame.height);
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (!mounted) {
          return;
        }
        setState(() {
          _rtBoxes = res;
          _rtCategories = yolox.category;
          predict_result =
              "${res.length} objects / ${endTime - startTime} ms per frame";
        });
      });
    } finally {
      yolox.close();
    }
  }

  Future<void> _realtimeResNet18() async {
    _displayDownloadBegin();
    final onnxFile = await downloadModel(
        "https://storage.googleapis.com/ailia-models/resnet18/resnet18.onnx",
        "resnet18.onnx",
        null,
        _displayDownloadProgress);
    await _displayDownloadEnd();
    if (onnxFile == null) {
      return;
    }
    final classifier = ImageClassificationResNet18();
    classifier.open(onnxFile, selectedEnvId);
    try {
      await _realtimeLoop((frame) async {
        int startTime = DateTime.now().millisecondsSinceEpoch;
        final label = classifier.run(_frameToImage(frame));
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (!mounted) {
          return;
        }
        setState(() {
          _rtLabel = label;
          predict_result = "${endTime - startTime} ms per frame";
        });
      });
    } finally {
      classifier.close();
    }
  }

  Future<void> _realtimeU2Net() async {
    _displayDownloadBegin();
    final u2netModelFile = await downloadModel(
        'https://storage.googleapis.com/ailia-models/u2net/u2net.onnx',
        'u2net.onnx',
        null,
        _displayDownloadProgress);
    await _displayDownloadEnd();
    if (u2netModelFile == null) {
      return;
    }
    final u2net = U2Net();
    u2net.open(u2netModelFile.path, envId: selectedEnvId);
    try {
      await _realtimeLoop((frame) async {
        int startTime = DateTime.now().millisecondsSinceEpoch;
        await u2net.setImage(_frameToImage(frame));
        final maskImage = u2net.run();
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (maskImage == null || !mounted) {
          return;
        }
        final maskUiImage = await imageToUiImage(maskImage);
        if (!mounted) {
          return;
        }
        setState(() {
          _rtOverlayImage = maskUiImage;
          predict_result = "${endTime - startTime} ms per frame";
        });
      });
    } finally {
      u2net.close();
    }
  }

  Future<void> _realtimeSam2() async {
    _displayDownloadBegin();
    const remotePath =
        'https://storage.googleapis.com/ailia-models/segment-anything-2/';
    final imageEncoderModelFile = await downloadModel(
        '${remotePath}image_encoder_hiera_t.onnx',
        'image_encoder_hiera_t.onnx',
        null,
        _displayDownloadProgress);
    final promptEncoderModelFile = await downloadModel(
        '${remotePath}prompt_encoder_hiera_t.onnx',
        'prompt_encoder_hiera_t.onnx',
        null,
        _displayDownloadProgress);
    final maskEncoderModelFile = await downloadModel(
        '${remotePath}mask_decoder_hiera_t.onnx',
        'mask_decoder_hiera_t.onnx',
        null,
        _displayDownloadProgress);
    await _displayDownloadEnd();
    if (imageEncoderModelFile == null ||
        promptEncoderModelFile == null ||
        maskEncoderModelFile == null) {
      return;
    }
    final segmentImage = SegmentImage();
    segmentImage.open(imageEncoderModelFile.path, promptEncoderModelFile.path,
        maskEncoderModelFile.path,
        envId: selectedEnvId);
    try {
      await _realtimeLoop((frame) async {
        int startTime = DateTime.now().millisecondsSinceEpoch;
        final inputImage = _frameToImage(frame);
        await segmentImage.setImage(inputImage);
        final point = img.Point(frame.width ~/ 2, frame.height ~/ 2);
        final maskImage = segmentImage.run([point]);
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (maskImage == null || !mounted) {
          return;
        }
        final result =
            await segmentImage.overlayMaskImage(inputImage, maskImage);
        final maskUiImage = await segmentImage.imageToUiImage(result);
        if (!mounted) {
          return;
        }
        setState(() {
          _rtOverlayImage = maskUiImage;
          predict_result = "${endTime - startTime} ms per frame";
        });
      });
    } finally {
      segmentImage.close();
    }
  }

  // ---------------------------------------------------------------------
  // Common helpers ported from the previous single screen implementation
  // ---------------------------------------------------------------------

  void _displayDownloadBegin() {
    setState(() {
      predict_result = "Downloading...";
    });
  }

  void _displayDownloadProgress(progress) {
    setState(() {
      predict_result = "Downloading... ${progress ~/ 1024 ~/ 1024} MB";
    });
  }

  Future<void> _displayDownloadEnd() async {
    setState(() {
      predict_result = "Download success.";
    });
    await Future.delayed(const Duration(milliseconds: 100));
  }

  void downloadModelFromModelList(
      int downloadCnt, List<String> modelList, Function callback) {
    String filename = basename(modelList[downloadCnt + 1]);
    String url =
        "https://storage.googleapis.com/ailia-models/${modelList[downloadCnt + 0]}/$filename";
    setState(() {
      predict_result = "Downloading ${modelList[downloadCnt + 1]}";
    });
    downloadModel(url, modelList[downloadCnt + 1], (file) {
      downloadCnt = downloadCnt + 2;
      if (downloadCnt >= modelList.length) {
        callback();
      } else {
        downloadModelFromModelList(downloadCnt, modelList, callback);
      }
    }, (progress) {
      setState(() {
        predict_result =
            "Downloading ${modelList[downloadCnt + 1]} ${progress ~/ 1024 ~/ 1024} MB";
      });
    });
  }

  // ---------------------------------------------------------------------
  // Demo runners
  // ---------------------------------------------------------------------

  Future<void> _run() async {
    if (_running && !widget.model.id.startsWith('whisper')) {
      return;
    }
    _running = true;
    try {
      try {
        await AiliaLicense.checkAndDownloadLicense();
        if (!await _prepareInput()) {
          return;
        }
      } catch (e) {
        setState(() {
          predict_result = "Error: $e";
        });
        return;
      }

      switch (widget.model.id) {
        case "sam2":
          _ailiaImageSegmentationSam2();
          break;
        case "u2net":
          _ailiaBackgroundRemovalU2Net();
          break;
        case "resnet18":
          _ailiaImageClassificationResNet18();
          break;
        case "whisper_tiny":
        case "whisper_small":
        case "whisper_medium":
        case "whisper_large_v3_turbo":
          if (_inputSource == InputSource.mic) {
            _ailiaAudioProcessingWhisperStreaming(
                widget.model.id, _virtualMemory);
          } else {
            _ailiaAudioProcessingWhisper(widget.model.id, _virtualMemory);
          }
          break;
        case "multilingual-e5":
          _ailiaNaturalLanguageProcessingMultilingualE5();
          break;
        case "yolox":
          _ailiaObjectDetectionYoloX();
          break;
        case "fugumt-en-ja":
          _ailiaNaturalLanguageProcessingFuguMTEnJa();
          break;
        case "fugumt-ja-en":
          _ailiaNaturalLanguageProcessingFuguMTJaEn();
          break;
        case "tacotron2":
          _ailiaTextToSpeechTactoron2();
          break;
        case "gpt-sovits-ja":
          _ailiaTextToSpeechGPTSoVITS_JA();
          break;
        case "gpt-sovits-en":
          _ailiaTextToSpeechGPTSoVITS_EN();
          break;
        case "gemma2":
          _ailiaLargeLanguageModelGemma2();
          break;
        case "gemma3-multimodal":
          _ailiaLargeLanguageModelGemma3Multimodal();
          break;
        default:
          throw (Exception("Unknown model type"));
      }
    } finally {
      _running = false;
    }
  }

  void _ailiaImageSegmentationSam2() async {
    image = await _loadInputUiImage("assets/truck.jpg");

    setState(() {
      isImageloaded = true;
    });

    _displayDownloadBegin();

    const remotePath =
        'https://storage.googleapis.com/ailia-models/segment-anything-2/';
    const imageEncoderModel = 'image_encoder_hiera_t.onnx';
    const promptEncoderModel = 'prompt_encoder_hiera_t.onnx';
    const maskEncoderModel = 'mask_decoder_hiera_t.onnx';

    final imageEncoderModelFile = await downloadModel(
        '$remotePath$imageEncoderModel',
        imageEncoderModel,
        null,
        _displayDownloadProgress);
    final promptEncoderModelFile = await downloadModel(
        '$remotePath$promptEncoderModel',
        promptEncoderModel,
        null,
        _displayDownloadProgress);
    final maskEncoderModelFile = await downloadModel(
        '$remotePath$maskEncoderModel',
        maskEncoderModel,
        null,
        _displayDownloadProgress);

    _displayDownloadEnd();

    if (imageEncoderModelFile == null ||
        promptEncoderModelFile == null ||
        maskEncoderModelFile == null) {
      return;
    }

    SegmentImage segmentImage = SegmentImage();
    segmentImage.open(imageEncoderModelFile.path, promptEncoderModelFile.path,
        maskEncoderModelFile.path,
        envId: selectedEnvId);

    final inputImage = await segmentImage.uiImageToImage(image!);
    await segmentImage.setImage(inputImage);

    // The default sample point matches the bundled truck image. For a
    // captured photo, use the image center.
    final point = _capturedBytes != null
        ? img.Point(inputImage.width ~/ 2, inputImage.height ~/ 2)
        : img.Point(500, 375);
    final maskImage = segmentImage.run([point]);

    if (maskImage == null) {
      segmentImage.close();
      return;
    }

    img.Image result =
        await segmentImage.overlayMaskImage(inputImage, maskImage);

    final maskUiImage = await segmentImage.imageToUiImage(result);
    setState(() {
      predict_result = 'Generated masks.';
      image = maskUiImage;
    });

    segmentImage.close();
  }

  void _ailiaBackgroundRemovalU2Net() async {
    image = await _loadInputUiImage("assets/input_u2net.png");

    setState(() {
      isImageloaded = true;
    });

    _displayDownloadBegin();

    const remotePath = 'https://storage.googleapis.com/ailia-models/u2net/';
    const u2netModel = 'u2net.onnx';

    final u2netModelFile = await downloadModel(
        '$remotePath$u2netModel', u2netModel, null, _displayDownloadProgress);

    _displayDownloadEnd();

    if (u2netModelFile == null) {
      return;
    }

    U2Net u2net = U2Net();
    u2net.open(u2netModelFile.path, envId: selectedEnvId);

    final inputImage = await uiImageToImage(image!);
    await u2net.setImage(inputImage);

    final maskImage = u2net.run();

    if (maskImage == null) {
      u2net.close();
      return;
    }

    final maskUiImage = await imageToUiImage(maskImage);
    setState(() {
      predict_result = 'Generated masks.';
      image = maskUiImage;
    });

    u2net.close();
  }

  void _ailiaImageClassificationResNet18() async {
    image = await _loadInputUiImage("assets/clock.jpg");
    setState(() {
      isImageloaded = true;
    });

    _displayDownloadBegin();
    downloadModel(
        "https://storage.googleapis.com/ailia-models/resnet18/resnet18.onnx",
        "resnet18.onnx", (onnx_file) async {
      await _displayDownloadEnd();
      image!.toByteData(format: ui.ImageByteFormat.rawRgba).then((data) {
        ailiaEnvironmentSample();

        int startTime = DateTime.now().millisecondsSinceEpoch;
        String classificationText = ailiaPredictSample(onnx_file, data!);
        int endTime = DateTime.now().millisecondsSinceEpoch;
        String profileText =
            "processing time : ${(endTime - startTime) / 1000} sec";

        setState(() {
          predict_result = "$classificationText\n$profileText";
        });
      });
    }, _displayDownloadProgress);
  }

  AudioProcessingWhisper whisper = AudioProcessingWhisper();
  AudioProcessingWhisperStreaming whisper_streaming =
      AudioProcessingWhisperStreaming();

  Stream<Uint8List>? stream;
  StreamSubscription? listener;
  bool terminating = false;

  void _intermediateCallback(List<SpeechText> text) {
    setState(() {
      predict_result = "${text[0].text}...";
    });
  }

  void _messageCallback(List<SpeechText> text) {
    setState(() {
      predict_result = "";
      for (int i = 0; i < text.length; i++) {
        predict_result += text[i].text;
      }
    });
  }

  void _finishCallback() {
    whisper_streaming.close();
    setState(() {
      predict_result = "Terminate success. You can run new whisper instance.";
    });
    terminating = false;
  }

  void _processSamples(samples) {
    // https://github.com/anarchuser/mic_stream/issues/94
    List<double> result = [];
    int UInt16Max = math.pow(2, 16).toInt();
    for (var i = 0; i < samples.length ~/ 2; i++) {
      int a = samples[2 * i + 1];
      int b = samples[2 * i];
      int c = 256 * a + b;
      if (2 * c > UInt16Max) {
        c = -UInt16Max + c;
      }
      result.add(c / 32738.0);
    }

    setState(() {
      mic_volume = "mic volume : ${result.reduce(math.max)}";
    });

    int sampleRate = 44100;
    whisper_streaming.send(result, sampleRate);
  }

  void _ailiaAudioProcessingWhisper(String modelType, bool virtualMemory) async {
    ByteData data = await rootBundle.load("assets/demo.wav");
    final wav = await Wav.read(data.buffer.asUint8List());
    AudioProcessingWhisper whisper = AudioProcessingWhisper();
    List<String> modelList = whisper.getModelList(modelType);
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      await _displayDownloadEnd();
      File vad_file = File(await getModelPath(modelList[1]));
      File onnx_encoder_file = File(await getModelPath(modelList[3]));
      File onnx_decoder_file = File(await getModelPath(modelList[5]));
      String text = await whisper.transcribe(wav, onnx_encoder_file,
          onnx_decoder_file, vad_file, selectedEnvId, modelType, virtualMemory);
      setState(() {
        predict_result = text;
      });
    });
  }

  void _ailiaAudioProcessingWhisperStreaming(
      String modelType, bool virtualMemory) async {
    List<String> modelList = whisper.getModelList(modelType);
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      await _displayDownloadEnd();

      setState(() {
        predict_result = "Please speak to mic.";
      });

      File vad_file = File(await getModelPath(modelList[1]));
      File onnx_encoder_file = File(await getModelPath(modelList[3]));
      File onnx_decoder_file = File(await getModelPath(modelList[5]));

      if (terminating) {
        return;
      }

      if (listener != null) {
        listener!.cancel();
        listener = null;
        whisper_streaming.terminate();
        setState(() {
          predict_result = "Please wait terminate.";
        });
        terminating = true;
        return;
      }

      String lang = "ja";
      await whisper_streaming.open(
          onnx_encoder_file,
          onnx_decoder_file,
          vad_file,
          selectedEnvId,
          modelType,
          lang,
          virtualMemory,
          _intermediateCallback,
          _messageCallback,
          _finishCallback);
      if (Platform.isIOS) {
        await Permission.microphone.request();
      }

      try {
        int sampleRate = 44100;
        stream = MicStream.microphone(
            audioSource: AudioSource.DEFAULT,
            sampleRate: sampleRate,
            channelConfig: ChannelConfig.CHANNEL_IN_MONO,
            audioFormat: AudioFormat.ENCODING_PCM_16BIT);
        listener = stream!.listen(_processSamples);
      } catch (e) {
        setState(() {
          predict_result = "Microphone is not available: $e";
        });
      }
    });
  }

  void _ailiaNaturalLanguageProcessingMultilingualE5() async {
    _displayDownloadBegin();
    downloadModel(
        "https://storage.googleapis.com/ailia-models/multilingual-e5/multilingual-e5-base.onnx",
        "multilingual-e5-base.onnx", (onnx_file) {
      downloadModel(
          "https://storage.googleapis.com/ailia-models/multilingual-e5/sentencepiece.bpe.model",
          "sentencepiece.bpe.model", (spe_file) async {
        await _displayDownloadEnd();
        NaturalLanguageProcessingMultilingualE5 e5 =
            NaturalLanguageProcessingMultilingualE5();
        e5.open(onnx_file, spe_file, selectedEnvId);
        String text1 = "Hello.";
        String text2 = "こんにちは。";
        String text3 = "Today is good day.";
        int startTime = DateTime.now().millisecondsSinceEpoch;
        List<double> embedding1 = e5.textEmbedding(text1);
        List<double> embedding2 = e5.textEmbedding(text2);
        List<double> embedding3 = e5.textEmbedding(text3);
        double sim1 = e5.cosSimilarity(embedding1, embedding2);
        double sim2 = e5.cosSimilarity(embedding1, embedding3);
        int endTime = DateTime.now().millisecondsSinceEpoch;
        String profileText =
            "processing time : ${(endTime - startTime) / 1000} sec";
        e5.close();
        setState(() {
          predict_result =
              "$text1 vs $text2 sim $sim1\n$text1 vs $text3 sim $sim2\n$profileText";
        });
      }, _displayDownloadProgress);
    }, _displayDownloadProgress);
  }

  void _ailiaObjectDetectionYoloX() async {
    final imData = await _loadInputEncodedBytes("assets/clock.jpg");
    image = await decodeImageFromList(imData);
    setState(() {
      isImageloaded = true;
    });

    _displayDownloadBegin();
    downloadModel(
        "https://storage.googleapis.com/ailia-models/yolox/yolox_s.opt.onnx",
        "yolox_s.opt.onnx", (onnx_file) async {
      await _displayDownloadEnd();
      ObjectDetectionYoloX yolox = ObjectDetectionYoloX();
      yolox.open(onnx_file, selectedEnvId);

      final decoded = img.decodeImage(imData)!;
      final width = decoded.width;
      final height = decoded.height;
      final imageWithoutAlpha = decoded.convert(numChannels: 3);
      final buffer = imageWithoutAlpha.getBytes(order: img.ChannelOrder.rgb);

      String resultSubText;

      int startTime = DateTime.now().millisecondsSinceEpoch;
      final res = yolox.run(buffer, width, height);
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      resultSubText = res
          .map((e) =>
              "x:${e.x} y:${e.y} w:${e.w} h:${e.h} p:${e.prob} label:${yolox.category[e.category]}")
          .join("\n");

      setState(() {
        predict_result = "$resultSubText\n$profileText";
      });
    }, _displayDownloadProgress);
  }

  void _ailiaNaturalLanguageProcessingFuguMTEnJa() {
    NaturalLanguageProcessingFuguMT fuguMT = NaturalLanguageProcessingFuguMT();
    List<String> modelList = fuguMT.getModelList(false);
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      await _displayDownloadEnd();

      File encoderFile =
          File(await getModelPath("fugumt-en-ja/seq2seq-lm-with-past.onnx"));
      File? decoderFile;
      File sourceFile = File(await getModelPath("fugumt-en-ja/source.spm"));
      File targetFile = File(await getModelPath("fugumt-en-ja/target.spm"));

      int startTime = DateTime.now().millisecondsSinceEpoch;
      String targetText = "Hello world.";
      String outputText = fuguMT.translate(targetText, encoderFile, decoderFile,
          sourceFile, targetFile, false, selectedEnvId);
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      setState(() {
        predict_result = "$targetText -> $outputText\n$profileText";
      });
    });
  }

  void _ailiaNaturalLanguageProcessingFuguMTJaEn() {
    NaturalLanguageProcessingFuguMT fuguMT = NaturalLanguageProcessingFuguMT();
    List<String> modelList = fuguMT.getModelList(true);
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      await _displayDownloadEnd();

      File encoderFile =
          File(await getModelPath("fugumt-ja-en/encoder_model.onnx"));
      File decoderFile =
          File(await getModelPath("fugumt-ja-en/decoder_model.onnx"));
      File sourceFile = File(await getModelPath("fugumt-ja-en/source.spm"));
      File targetFile = File(await getModelPath("fugumt-ja-en/target.spm"));

      int startTime = DateTime.now().millisecondsSinceEpoch;
      String targetText = "こんにちは世界。";
      String outputText = fuguMT.translate(targetText, encoderFile, decoderFile,
          sourceFile, targetFile, true, selectedEnvId);
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      setState(() {
        predict_result = "$targetText -> $outputText\n$profileText";
      });
    });
  }

  void _ailiaTextToSpeechTactoron2() {
    TextToSpeech textToSpeech = TextToSpeech();
    List<String> modelList =
        textToSpeech.getModelList(TextToSpeech.MODEL_TYPE_TACOTRON2);
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      await _displayDownloadEnd();

      String encoderFile = await getModelPath("encoder.onnx");
      String decoderFile = await getModelPath("decoder_iter.onnx");
      String postnetFile = await getModelPath("postnet.onnx");
      String waveglowFile = await getModelPath("waveglow.onnx");
      String? sslFile;

      String dicFolder = await getModelPath("open_jtalk_dic_utf_8-1.11/");
      String targetText = "Hello world.";
      String outputPath = await getModelPath("temp$_runCounter.wav");

      int startTime = DateTime.now().millisecondsSinceEpoch;
      await textToSpeech.inference(
          targetText,
          outputPath,
          encoderFile,
          decoderFile,
          postnetFile,
          waveglowFile,
          sslFile,
          dicFolder,
          null,
          TextToSpeech.MODEL_TYPE_TACOTRON2);
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      setState(() {
        predict_result = profileText;
      });
    });
  }

  void _ailiaTextToSpeechGPTSoVITS_JA() {
    TextToSpeech textToSpeech = TextToSpeech();
    List<String> modelList =
        textToSpeech.getModelList(TextToSpeech.MODEL_TYPE_GPT_SOVITS_JA);
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      await _displayDownloadEnd();

      String encoderFile = await getModelPath("t2s_encoder.onnx");
      String decoderFile = await getModelPath("t2s_fsdec.onnx");
      String postnetFile = await getModelPath("t2s_sdec.opt.onnx");
      String waveglowFile = await getModelPath("vits.onnx");
      String sslFile = await getModelPath("cnhubert.onnx");

      String dicFolder = await getModelPath("open_jtalk_dic_utf_8-1.11/");
      String targetText = "Hello world.";
      String outputPath = await getModelPath("temp$_runCounter.wav");

      int startTime = DateTime.now().millisecondsSinceEpoch;
      await textToSpeech.inference(
          targetText,
          outputPath,
          encoderFile,
          decoderFile,
          postnetFile,
          waveglowFile,
          sslFile,
          dicFolder,
          null,
          TextToSpeech.MODEL_TYPE_GPT_SOVITS_JA);
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      setState(() {
        predict_result = profileText;
      });
    });
  }

  void _ailiaTextToSpeechGPTSoVITS_EN() {
    TextToSpeech textToSpeech = TextToSpeech();
    List<String> modelList =
        textToSpeech.getModelList(TextToSpeech.MODEL_TYPE_GPT_SOVITS_EN);
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      await _displayDownloadEnd();

      String encoderFile = await getModelPath("t2s_encoder.onnx");
      String decoderFile = await getModelPath("t2s_fsdec.onnx");
      String postnetFile = await getModelPath("t2s_sdec.opt.onnx");
      String waveglowFile = await getModelPath("vits.onnx");
      String sslFile = await getModelPath("cnhubert.onnx");

      String dicFolderOpenJtalk =
          await getModelPath("open_jtalk_dic_utf_8-1.11/");
      String dicFolderEn = await getModelPath("/");
      String targetText = "Hello world.";
      String outputPath = await getModelPath("temp$_runCounter.wav");

      int startTime = DateTime.now().millisecondsSinceEpoch;
      await textToSpeech.inference(
          targetText,
          outputPath,
          encoderFile,
          decoderFile,
          postnetFile,
          waveglowFile,
          sslFile,
          dicFolderOpenJtalk,
          dicFolderEn,
          TextToSpeech.MODEL_TYPE_GPT_SOVITS_EN);
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      setState(() {
        predict_result = profileText;
      });
    });
  }

  void _ailiaLargeLanguageModelGemma2() async {
    LargeLanguageModel llm = LargeLanguageModel();
    List<String> modelList = llm.getModelList();
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      await _displayDownloadEnd();

      setState(() {
        predict_result = "Model downloaded. Ready for inference.";
      });

      await _performGemma2Inference(llm);
    });
  }

  Future<void> _performGemma2Inference(LargeLanguageModel llm) async {
    try {
      setState(() {
        predict_result = "Loading model with selected backend...";
      });

      File modelFile = File(await getModelPath("gemma-2-2b-it-Q4_K_M.gguf"));
      String inputText = "こんにちは。";

      int startTime = DateTime.now().millisecondsSinceEpoch;

      // ailia LLM has its own backend list; use the LLM selection.
      String selectedBackend = BackendState.instance.selectedLlmBackend.value;

      llm.openWithBackendName(modelFile, selectedBackend);
      llm.setSystemPrompt("語尾に「わん」をつけてください。");
      String outputText = llm.chat(inputText);

      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      setState(() {
        predict_result = "$inputText -> $outputText\n$profileText";
      });

      llm.close();
    } catch (e) {
      setState(() {
        predict_result = "Inference Error: $e";
      });
    }
  }

  void _ailiaLargeLanguageModelGemma3Multimodal() async {
    MultimodalLargeLanguageModel multimodalLLM =
        MultimodalLargeLanguageModel();
    List<String> modelList = multimodalLLM.getModelList();
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      try {
        String imagePath;
        if (_capturedPath != null) {
          imagePath = _capturedPath!;
        } else {
          setState(() {
            predict_result = "Downloading sample image...";
          });
          File imageFile = await MultimodalLargeLanguageModel.downloadFile(
              "https://storage.googleapis.com/ailia-models/misc/sample_image.jpg",
              await getModelPath("sample_image.jpg"));
          imagePath = imageFile.path;
        }

        Uint8List imageBytes = await File(imagePath).readAsBytes();
        if (_capturedPath == null) {
          // The captured frame is already shown as the frozen camera
          // preview; only show the sample image separately.
          image = await decodeImageFromList(imageBytes);
        }

        setState(() {
          isImageloaded = _capturedPath == null;
          predict_result = "Models downloaded. Ready for inference.";
        });

        await _displayDownloadEnd();

        await _performGemma3MultimodalInference(multimodalLLM, imagePath);
      } catch (e) {
        setState(() {
          predict_result = "Error: $e";
        });
      }
    });
  }

  Future<void> _performGemma3MultimodalInference(
      MultimodalLargeLanguageModel multimodalLLM, String imagePath) async {
    try {
      setState(() {
        predict_result = "Loading model with selected backend...";
      });

      File modelFile = File(await getModelPath("gemma-3-4b-it-Q4_K_M.gguf"));
      File mmprojFile =
          File(await getModelPath("gemma-3-4b-it-GGUF_mmproj-model-f16.gguf"));

      String inputText = "この画像を簡潔に説明してください。";

      int startTime = DateTime.now().millisecondsSinceEpoch;

      // ailia LLM has its own backend list; use the LLM selection.
      String selectedBackend = BackendState.instance.selectedLlmBackend.value;

      multimodalLLM.openWithBackendName(modelFile, mmprojFile, selectedBackend);
      multimodalLLM.setSystemPrompt("画像を2-3文で簡潔に説明してください。");
      String outputText = multimodalLLM.chatWithImage(inputText, imagePath);

      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      setState(() {
        predict_result = "$inputText -> $outputText\n$profileText";
      });

      multimodalLLM.close();
    } catch (e) {
      setState(() {
        predict_result = "Inference Error: $e";
      });
    }
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  Widget _buildImage(BuildContext context) {
    if (isImageloaded && image != null) {
      double screenHeight = MediaQuery.of(context).size.height;
      double height = screenHeight * 0.45;
      double width = height * image!.width / image!.height;
      return SizedBox(
        width: width,
        height: height,
        child: CustomPaint(
          painter: ImageEditor(image: image!),
        ),
      );
    } else {
      return const SizedBox.shrink();
    }
  }

  Widget _buildInputSourceSelector() {
    if (_supportsCamera) {
      return SegmentedButton<InputSource>(
        segments: const [
          ButtonSegment(
              value: InputSource.sample,
              label: Text('Image'),
              icon: Icon(Icons.image)),
          ButtonSegment(
              value: InputSource.camera,
              label: Text('Web Camera'),
              icon: Icon(Icons.videocam)),
        ],
        selected: {_inputSource},
        onSelectionChanged: (selection) {
          _switchInputSource(selection.first);
        },
      );
    }
    if (_supportsMic) {
      return Column(
        children: [
          SegmentedButton<InputSource>(
            segments: const [
              ButtonSegment(
                  value: InputSource.sample,
                  label: Text('Audio File'),
                  icon: Icon(Icons.audio_file)),
              ButtonSegment(
                  value: InputSource.mic,
                  label: Text('Microphone'),
                  icon: Icon(Icons.mic)),
            ],
            selected: {_inputSource},
            onSelectionChanged: (selection) {
              _switchInputSource(selection.first);
            },
          ),
          SizedBox(
            width: 320,
            child: SwitchListTile(
              dense: true,
              title: const Text('Use virtual memory'),
              value: _virtualMemory,
              onChanged: (v) {
                setState(() {
                  _virtualMemory = v;
                });
              },
            ),
          ),
        ],
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildCameraPreview() {
    if (!_supportsCamera || _inputSource != InputSource.camera) {
      return const SizedBox.shrink();
    }
    if (_cameraError != null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Text(_cameraError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    Widget preview;
    if (_usesMacCamera) {
      preview = CameraMacOSView(
        cameraMode: CameraMacOSMode.photo,
        pictureFormat: PictureFormat.jpg,
        resolution: PictureResolution.medium,
        fit: BoxFit.fill,
        enableAudio: false,
        onCameraInizialized: (CameraMacOSController controller) {
          setState(() {
            _macCameraController = controller;
          });
        },
      );
    } else {
      final controller = _cameraController;
      if (controller == null || !controller.value.isInitialized) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        );
      }
      preview = CameraPreview(controller);
    }
    // After a still capture (e.g. gemma3 multimodal), freeze the visible
    // preview on the captured frame while the camera keeps running
    // underneath. Tap the frozen image to return to the live view.
    final frozen = !_realtimeActive && _capturedBytes != null;
    return SizedBox(
      height: 320,
      child: AspectRatio(
        aspectRatio: _cameraAspect,
        child: Stack(
          fit: StackFit.expand,
          children: [
            preview,
            if (frozen)
              GestureDetector(
                onTap: () {
                  setState(() {
                    _capturedBytes = null;
                    _capturedPath = null;
                  });
                },
                child: Image.memory(
                  _capturedBytes!,
                  fit: BoxFit.contain,
                ),
              ),
            if (!frozen)
              CustomPaint(
                painter: CameraOverlayPainter(
                  boxes: _rtBoxes,
                  categories: _rtCategories,
                  overlayImage: _rtOverlayImage,
                  label: _rtLabel,
                ),
              ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    final color = categoryColor(context, model.category);
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: Text(model.name),
        actions: [
          // ailia LLM uses its own backend list, so switch the selector.
          BackendSelector(forLlm: model.category == 'Large Language Model'),
        ],
      ),
      body: SingleChildScrollView(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                Chip(
                  avatar: Icon(categoryIcon(model.category),
                      size: 18, color: color),
                  label: Text(model.category),
                ),
                const SizedBox(height: 8),
                _buildInputSourceSelector(),
                const SizedBox(height: 8),
                _buildCameraPreview(),
                _buildImage(context),
                const SizedBox(height: 8),
                Text(predict_result),
                Text(mic_volume),
              ],
            ),
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () {
          if (_supportsRealtime) {
            _toggleRealtime();
            return;
          }
          _runCounter++;
          _run();
        },
        icon: Icon(_realtimeActive ? Icons.stop : Icons.play_arrow),
        label: Text(_realtimeActive ? 'Stop' : 'Run'),
      ),
    );
  }
}

/// One camera frame as tightly packed RGB bytes.
class _CameraFrame {
  _CameraFrame(this.rgb, this.width, this.height);

  final Uint8List rgb;
  final int width;
  final int height;
}

/// Draws realtime inference results (bounding boxes, masks, labels)
/// on top of the live camera preview.
class CameraOverlayPainter extends CustomPainter {
  CameraOverlayPainter({
    required this.boxes,
    required this.categories,
    this.overlayImage,
    this.label = '',
  });

  final List<AiliaDetectorObject> boxes;
  final List<String> categories;
  final ui.Image? overlayImage;
  final String label;

  static const List<Color> _palette = [
    Colors.red,
    Colors.lime,
    Colors.blue,
    Colors.yellow,
    Colors.cyan,
    Colors.orange,
    Colors.purple,
    Colors.pink,
  ];

  @override
  void paint(Canvas canvas, ui.Size size) {
    final overlay = overlayImage;
    if (overlay != null) {
      final src = Rect.fromLTWH(
          0, 0, overlay.width.toDouble(), overlay.height.toDouble());
      final dst = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawImageRect(
          overlay, src, dst, Paint()..color = Colors.white.withOpacity(0.7));
    }

    for (final box in boxes) {
      final color = _palette[box.category % _palette.length];
      // Detector coordinates are normalized to 0..1.
      final rect = Rect.fromLTWH(
        box.x * size.width,
        box.y * size.height,
        box.w * size.width,
        box.h * size.height,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
      final name = box.category < categories.length
          ? categories[box.category]
          : '${box.category}';
      _drawLabel(canvas, '$name ${(box.prob * 100).toStringAsFixed(0)}%',
          rect.left, rect.top, color);
    }

    if (label.isNotEmpty) {
      _drawLabel(canvas, label, 4, 4, Colors.black54);
    }
  }

  void _drawLabel(Canvas canvas, String text, double x, double y, Color bg) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect =
        Rect.fromLTWH(x, y, painter.width + 8, painter.height + 4);
    canvas.drawRect(rect, Paint()..color = bg.withOpacity(0.7));
    painter.paint(canvas, Offset(x + 4, y + 2));
  }

  @override
  bool shouldRepaint(CameraOverlayPainter oldDelegate) {
    return oldDelegate.boxes != boxes ||
        oldDelegate.overlayImage != overlayImage ||
        oldDelegate.label != label;
  }
}

class ImageEditor extends CustomPainter {
  ImageEditor({
    required this.image,
  });

  ui.Image image;

  @override
  void paint(Canvas canvas, ui.Size size) {
    final src = Rect.fromLTWH(
        0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, src, dst, Paint());
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) {
    return false;
  }
}
