import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ailia/ailia_license.dart';
import 'package:audioplayers/audioplayers.dart';
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
  int _runCounter = 0;

  InputSource _inputSource = InputSource.sample;
  bool _virtualMemory = false;
  bool _liveTranscribe = false;

  // Camera state
  CameraController? _cameraController;
  // macOS uses the camera_macos package; the view initializes the controller.
  CameraMacOSController? _macCameraController;
  String? _cameraError;
  Uint8List? _capturedBytes;
  String? _capturedPath;

  // Waveform state shared by the microphone input and TTS playback:
  // peak amplitude (0..1) per ~10ms block, most recent block last.
  static const int _waveformBlocks = 300;
  final List<double> _waveform = [];
  Timer? _playbackTimer;

  // Meeting-minutes style transcript of speech recognition results.
  final List<String> _transcript = [];

  // Text spoken by the text-to-speech demos.
  late final TextEditingController _ttsTextController =
      TextEditingController(text: widget.model.defaultTtsText ?? '');

  // Query for the multimodal (image + text) LLM demo.
  final TextEditingController _vlmQueryController =
      TextEditingController(text: 'この画像を簡潔に説明してください。');

  bool get _isVlmModel => widget.model.input == ModelInputKind.imageText;

  // LLM chat state. The model stays open so the conversation continues.
  LargeLanguageModel? _chatLlm;
  String? _chatBackend;
  bool _chatGenerating = false;
  final List<Map<String, String>> _chatMessages = [];
  final TextEditingController _chatTextController = TextEditingController();
  String _systemPrompt = 'あなたは親切なアシスタントです。';

  // Progress / error display, separated from the inference result text.
  String _status = '';
  double? _downloadProgress;
  int _lastProgressMs = 0;
  String? _errorText;

  // Recording start time shown next to the mic waveform.
  DateTime? _recStart;

  // macOS mic_stream only supports 48kHz; other platforms use 44.1kHz.
  final int _micSampleRate =
      !kIsWeb && Platform.isMacOS ? 48000 : 44100;

  // Last synthesized audio, replayable without re-synthesizing.
  String? _lastTtsPath;

  final ScrollController _scrollController = ScrollController();

  // Realtime camera inference state
  bool _realtimeActive = false;
  List<AiliaDetectorObject> _rtBoxes = [];
  List<String> _rtCategories = const [];
  ui.Image? _rtOverlayImage;
  // The exact camera frame the current results were computed on. Shown
  // instead of the live preview so results never lag behind the video.
  ui.Image? _rtFrameImage;
  String _rtLabel = '';
  double _cameraAspect = 4 / 3;
  CameraImageData? _macLatestFrame;

  ui.Image? image;

  int get selectedEnvId => BackendState.instance.selectedEnvId.value;

  /// setState that is safe to call from async callbacks which may fire
  /// after the screen has been disposed (downloads, isolates, streams).
  void _safeSetState(VoidCallback fn) {
    if (!mounted) {
      return;
    }
    setState(fn);
  }

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
  void initState() {
    super.initState();
    final asset = widget.model.sampleAsset;
    if (asset != null) {
      _loadSampleImage(asset);
    }
    if (_isVlmModel) {
      _loadVlmSampleImage();
    }
  }

  /// Shows the multimodal demo's sample image (downloaded, not bundled)
  /// next to the query box before the first run.
  Future<void> _loadVlmSampleImage() async {
    try {
      final imageFile = await MultimodalLargeLanguageModel.downloadFile(
          "https://storage.googleapis.com/ailia-models/misc/sample_image.jpg",
          await getModelPath("sample_image.jpg"));
      final loaded = await decodeImageFromList(await imageFile.readAsBytes());
      _safeSetState(() {
        image = loaded;
      });
    } catch (_) {
      // The image appears after the model download instead.
    }
  }

  /// Shows the bundled sample image before the first run.
  Future<void> _loadSampleImage(String asset) async {
    final data = await rootBundle.load(asset);
    final loaded = await decodeImageFromList(data.buffer.asUint8List());
    _safeSetState(() {
      image = loaded;
    });
  }

  @override
  void dispose() {
    _realtimeActive = false;
    _playbackTimer?.cancel();
    _ttsTextController.dispose();
    _vlmQueryController.dispose();
    _chatTextController.dispose();
    // While a reply is streaming, chatStream still holds the native
    // handle; _sendChatMessage closes it when the loop ends.
    if (!_chatGenerating) {
      _chatLlm?.close();
      _chatLlm = null;
    }
    _scrollController.dispose();
    _cameraController?.dispose();
    _macCameraController?.destroy();
    // Stop the speech recognition isolate; its finish callback closes it.
    if (listener != null) {
      listener!.cancel();
      listener = null;
      whisper_streaming.terminate();
    }
    super.dispose();
  }

  /// Streams the waveform of a synthesized wav file into the waveform
  /// display, following the playback position in time.
  /// Peak amplitude per ~10ms block, the unit of the waveform display.
  List<double> _peakBlocks(List<double> samples, int sampleRate) {
    final blockSize = sampleRate ~/ 100;
    final blocks = <double>[];
    for (int i = 0; i + blockSize <= samples.length; i += blockSize) {
      double peak = 0;
      for (int j = i; j < i + blockSize; j++) {
        peak = math.max(peak, samples[j].abs());
      }
      blocks.add(peak);
    }
    return blocks;
  }

  /// Appends blocks to the scrolling waveform, keeping the last
  /// [_waveformBlocks] entries.
  void _pushWaveform(List<double> blocks) {
    _waveform.addAll(blocks);
    if (_waveform.length > _waveformBlocks) {
      _waveform.removeRange(0, _waveform.length - _waveformBlocks);
    }
  }

  Future<void> _startPlaybackWaveform(String wavPath) async {
    final wav = await Wav.readFile(wavPath);
    if (wav.channels.isEmpty) {
      return;
    }
    final blocks = _peakBlocks(wav.channels[0], wav.samplesPerSecond);
    if (blocks.isEmpty || !mounted) {
      return;
    }

    _playbackTimer?.cancel();
    _safeSetState(() {
      _waveform.clear();
    });

    final startMs = DateTime.now().millisecondsSinceEpoch;
    int nextBlock = 0;
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 33), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      final elapsedMs = DateTime.now().millisecondsSinceEpoch - startMs;
      int target = math.min(elapsedMs ~/ 10, blocks.length);
      if (target > nextBlock) {
        _pushWaveform(blocks.sublist(nextBlock, target));
        nextBlock = target;
        _safeSetState(() {});
      }
      if (nextBlock >= blocks.length) {
        timer.cancel();
      }
    });
  }

  // ---------------------------------------------------------------------
  // Input helpers
  // ---------------------------------------------------------------------

  Future<void> _switchInputSource(InputSource source) async {
    if (source == InputSource.camera) {
      _safeSetState(() {
        _inputSource = source;
        _cameraError = null;
        _capturedBytes = null;
        _capturedPath = null;
        image = null;
        _rtBoxes = [];
        _rtOverlayImage = null;
        _rtFrameImage = null;
        _rtLabel = '';
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
      if (mounted) _safeSetState(() {});
    } else {
      _realtimeActive = false;
      _stopSpeechRecognition();
      final controller = _cameraController;
      _cameraController = null;
      await controller?.dispose();
      final macController = _macCameraController;
      _macCameraController = null;
      _macLatestFrame = null;
      await macController?.destroy();
      _safeSetState(() {
        _inputSource = source;
        _capturedBytes = null;
        _capturedPath = null;
        _rtBoxes = [];
        _rtOverlayImage = null;
        _rtFrameImage = null;
        _rtLabel = '';
        _waveform.clear();
      });
      final asset = widget.model.sampleAsset;
      if (source == InputSource.sample && asset != null) {
        _loadSampleImage(asset);
      }
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
          _showError(_cameraError ?? 'Camera is not ready.');
          return false;
        }
        final shot = await controller.takePicture();
        final bytes = shot?.bytes;
        if (bytes == null) {
          _showError('Failed to capture image.');
          return false;
        }
        _capturedBytes = bytes;
        // Some demos (multimodal LLM) need a file path.
        final file =
            File('${Directory.systemTemp.path}/ailia_camera_capture.jpg');
        await file.writeAsBytes(bytes);
        _capturedPath = file.path;
        return true;
      }
      final controller = _cameraController;
      if (controller == null || !controller.value.isInitialized) {
        _showError(_cameraError ?? 'Camera is not ready.');
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

  _CameraFrame _streamToFrame(CameraImageData data) {
    // camera_macos streams frames as ARGB, alpha first: the native side
    // converts its BGRA capture through NSBitmapImageRep, whose meshed
    // layout is A,R,G,B. Reading at the wrong offset shows up as a blue
    // or red tint because the constant 255 alpha lands on a color
    // channel. One pass builds both the RGB buffer for inference and
    // the RGBA buffer for display.
    final out = Uint8List(data.width * data.height * 3);
    final rgba = Uint8List(data.width * data.height * 4);
    int o = 0;
    int a = 0;
    for (int y = 0; y < data.height; y++) {
      int i = y * data.bytesPerRow;
      for (int x = 0; x < data.width; x++) {
        final r = data.bytes[i + 1];
        final g = data.bytes[i + 2];
        final b = data.bytes[i + 3];
        out[o++] = r;
        out[o++] = g;
        out[o++] = b;
        rgba[a++] = r;
        rgba[a++] = g;
        rgba[a++] = b;
        rgba[a++] = 255;
        i += 4;
      }
    }
    return _CameraFrame(out, data.width, data.height, rgba: rgba);
  }

  /// Grabs the current camera frame as tightly packed RGB bytes.
  Future<_CameraFrame?> _grabCameraFrame() async {
    if (_usesMacCamera) {
      final data = _macLatestFrame;
      if (data == null) {
        return null;
      }
      return _streamToFrame(data);
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

  /// Converts a camera frame to a ui.Image for display, using the raw
  /// pixel decoder (no PNG round trip).
  Future<ui.Image> _frameToUiImage(_CameraFrame frame) {
    final rgba = Uint8List(frame.width * frame.height * 4);
    int o = 0;
    for (int i = 0; i < frame.rgb.length; i += 3) {
      rgba[o++] = frame.rgb[i];
      rgba[o++] = frame.rgb[i + 1];
      rgba[o++] = frame.rgb[i + 2];
      rgba[o++] = 255;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(rgba, frame.width, frame.height,
        ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
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
      _safeSetState(() {
        _cameraAspect = aspect;
      });
    }
  }

  Future<void> _toggleRealtime() async {
    if (_realtimeActive) {
      _safeSetState(() {
        _realtimeActive = false;
      });
      return;
    }
    if (_usesMacCamera && _macCameraController == null) {
      _showError(_cameraError ?? 'Camera is not ready.');
      return;
    }
    _safeSetState(() {
      _realtimeActive = true;
      _rtBoxes = [];
      _rtOverlayImage = null;
      _rtFrameImage = null;
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
          _safeSetState(() {
            predict_result = 'Realtime mode is not supported for this model.';
          });
      }
    } catch (e) {
      _showError(e);
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
        _safeSetState(() {});
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

  /// Downloads the given (remote folder, filename) model files with
  /// progress display. Returns null (and shows an error) on failure.
  Future<List<File>?> _downloadModelFiles(List<(String, String)> models) async {
    _displayDownloadBegin();
    final files = <File>[];
    for (final (folder, filename) in models) {
      final file = await downloadModel(
          "https://storage.googleapis.com/ailia-models/$folder/$filename",
          filename,
          null,
          (int downloaded, int total) =>
              _displayDownloadProgress(downloaded, total, filename: filename));
      if (file == null) {
        _showError("Download failed: $filename");
        return null;
      }
      files.add(file);
    }
    await _displayDownloadEnd();
    return files;
  }

  /// Shared skeleton of the realtime demos: download the model files,
  /// open the model, run [onFrame] until stopped, then close.
  Future<void> _runRealtimeModel({
    required List<(String, String)> models,
    required void Function(List<File> files) openModel,
    required Future<void> Function(_CameraFrame frame) onFrame,
    required void Function() closeModel,
  }) async {
    final files = await _downloadModelFiles(models);
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
        final frameImage = await _frameToUiImage(frame);
        if (!mounted) {
          return;
        }
        _safeSetState(() {
          _rtBoxes = res;
          _rtCategories = yolox.category;
          _rtFrameImage = frameImage;
          predict_result =
              "${res.length} objects / ${endTime - startTime} ms per frame";
        });
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
        final label = await classifier.run(_frameToImage(frame));
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (!mounted) {
          return;
        }
        _safeSetState(() {
          _rtLabel = label;
          predict_result = "${endTime - startTime} ms per frame";
        });
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
        await u2net.setImage(_frameToImage(frame));
        final maskImage = u2net.run();
        int endTime = DateTime.now().millisecondsSinceEpoch;
        if (maskImage == null || !mounted) {
          return;
        }
        final maskUiImage = await imageToUiImage(maskImage);
        final frameImage = await _frameToUiImage(frame);
        if (!mounted) {
          return;
        }
        _safeSetState(() {
          // Show the processed frame with its mask so the result never
          // lags behind the live preview.
          _rtFrameImage = frameImage;
          _rtOverlayImage = maskUiImage;
          predict_result = "${endTime - startTime} ms per frame";
        });
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
        final maskUiImage = await imageToUiImage(result);
        if (!mounted) {
          return;
        }
        _safeSetState(() {
          // The result already contains the processed frame, so show it
          // as the full-opacity background.
          _rtFrameImage = maskUiImage;
          predict_result = "${endTime - startTime} ms per frame";
        });
      },
    );
  }

// ---------------------------------------------------------------------
// Common helpers ported from the previous single screen implementation
// ---------------------------------------------------------------------

  void _displayDownloadBegin() {
    _safeSetState(() {
      _errorText = null;
      _status = "Downloading...";
      _downloadProgress = null;
    });
  }

  void _displayDownloadProgress(int downloaded, int total, {String? filename}) {
    _safeSetState(() {
      _downloadProgress = total > 0 ? downloaded / total : null;
      final name = filename == null ? "" : " $filename";
      final mb = "${downloaded ~/ 1024 ~/ 1024} MB";
      _status = total > 0
          ? "Downloading$name ($mb / ${total ~/ 1024 ~/ 1024} MB)"
          : "Downloading$name ($mb)";
    });
  }

  Future<void> _displayDownloadEnd() async {
    _safeSetState(() {
      _status = "";
      _downloadProgress = null;
    });
    await Future.delayed(const Duration(milliseconds: 100));
  }

  void _showError(Object error) {
    if (!mounted) {
      return;
    }
    _safeSetState(() {
      _errorText = "$error";
      _status = "";
      _downloadProgress = null;
    });
  }

  void downloadModelFromModelList(
      int downloadCnt, List<String> modelList, Function callback) {
    String filename = basename(modelList[downloadCnt + 1]);
    String url =
        "https://storage.googleapis.com/ailia-models/${modelList[downloadCnt + 0]}/$filename";
    _safeSetState(() {
      _errorText = null;
      _status = "Downloading ${modelList[downloadCnt + 1]}";
      _downloadProgress = null;
    });
    downloadModel(url, modelList[downloadCnt + 1], (file) {
      downloadCnt = downloadCnt + 2;
      if (downloadCnt >= modelList.length) {
        _safeSetState(() {
          _status = "";
          _downloadProgress = null;
        });
        callback();
      } else {
        downloadModelFromModelList(downloadCnt, modelList, callback);
      }
    }, (int downloaded, int total) {
      _displayDownloadProgress(downloaded, total,
          filename: modelList[downloadCnt + 1]);
    });
  }

// ---------------------------------------------------------------------
// Demo runners
// ---------------------------------------------------------------------

  Future<void> _run() async {
    if (widget.model.isTextToSpeech && _ttsTextController.text.trim().isEmpty) {
      _safeSetState(() {
        predict_result = 'Please enter text to speak.';
      });
      return;
    }
    _safeSetState(() {
      _errorText = null;
    });
    try {
      await AiliaLicense.checkAndDownloadLicense();
      if (!await _prepareInput()) {
        return;
      }
    } catch (e) {
      _showError(e);
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
      case "sensevoice_small":
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
        _runTextToSpeech(TextToSpeech.MODEL_TYPE_TACOTRON2);
        break;
      case "gpt-sovits-ja":
        _runTextToSpeech(TextToSpeech.MODEL_TYPE_GPT_SOVITS_JA);
        break;
      case "gpt-sovits-en":
        _runTextToSpeech(TextToSpeech.MODEL_TYPE_GPT_SOVITS_EN);
        break;
      case "gpt-sovits-zh":
        _runTextToSpeech(TextToSpeech.MODEL_TYPE_GPT_SOVITS_ZH);
        break;
      case "gemma2":
      case "gemma4-e2b":
        try {
          await _ensureChatModel();
        } catch (e) {
          _showError(e);
        }
        break;
      case "gemma3-multimodal":
        _ailiaLargeLanguageModelGemma3Multimodal();
        break;
      default:
        throw (Exception("Unknown model type"));
    }
  }

  void _ailiaImageSegmentationSam2() async {
    image = await _loadInputUiImage(widget.model.sampleAsset!);
    _safeSetState(() {});

    final files = await _downloadModelFiles(imageModelFiles['sam2']!);
    if (files == null) {
      return;
    }

    SegmentImage segmentImage = SegmentImage();
    segmentImage.open(files[0].path, files[1].path, files[2].path,
        envId: selectedEnvId);

    final inputImage = await uiImageToImage(image!);
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

    final maskUiImage = await imageToUiImage(result);
    _safeSetState(() {
      predict_result = 'Generated masks.';
      image = maskUiImage;
    });

    segmentImage.close();
  }

  void _ailiaBackgroundRemovalU2Net() async {
    image = await _loadInputUiImage(widget.model.sampleAsset!);
    _safeSetState(() {});

    final files = await _downloadModelFiles(imageModelFiles['u2net']!);
    if (files == null) {
      return;
    }

    U2Net u2net = U2Net();
    u2net.open(files[0].path, envId: selectedEnvId);

    final inputImage = await uiImageToImage(image!);
    await u2net.setImage(inputImage);

    final maskImage = u2net.run();

    if (maskImage == null) {
      u2net.close();
      return;
    }

    final maskUiImage = await imageToUiImage(maskImage);
    _safeSetState(() {
      predict_result = 'Generated masks.';
      image = maskUiImage;
    });

    u2net.close();
  }

  void _ailiaImageClassificationResNet18() async {
    image = await _loadInputUiImage(widget.model.sampleAsset!);
    _safeSetState(() {});

    final files = await _downloadModelFiles(imageModelFiles['resnet18']!);
    if (files == null) {
      return;
    }
    final classifier = ImageClassificationResNet18();
    classifier.open(files[0], selectedEnvId);
    try {
      int startTime = DateTime.now().millisecondsSinceEpoch;
      String classificationText =
          await classifier.run(await uiImageToImage(image!));
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      _safeSetState(() {
        predict_result = "$classificationText\n$profileText";
      });
    } catch (e) {
      _showError(e);
    } finally {
      classifier.close();
    }
  }

  AudioProcessingWhisper whisper = AudioProcessingWhisper();
  AudioProcessingWhisperStreaming whisper_streaming =
      AudioProcessingWhisperStreaming();

  Stream<Uint8List>? stream;
  StreamSubscription? listener;
  bool terminating = false;

  String _formatTimeStamp(double sec) {
    final total = sec.floor();
    final minutes = (total ~/ 60).toString().padLeft(2, '0');
    final seconds = (total % 60).toString().padLeft(2, '0');
    return "$minutes:$seconds";
  }

  String _formatTranscriptLine(SpeechText text) {
    return "[${_formatTimeStamp(text.timeStampBegin)} - "
        "${_formatTimeStamp(text.timeStampEnd)}] ${text.text}";
  }

  void _intermediateCallback(List<SpeechText> text) {
    _safeSetState(() {
      predict_result = "${text[0].text}...";
    });
  }

  void _messageCallback(List<SpeechText> text) {
    _safeSetState(() {
      predict_result = "";
      for (int i = 0; i < text.length; i++) {
        _transcript.add(_formatTranscriptLine(text[i]));
      }
    });
    _scrollToBottom();
  }

  void _finishCallback() {
    whisper_streaming.close();
    _safeSetState(() {
      predict_result = "Complete.";
    });
    terminating = false;
  }

  /// Whether microphone speech recognition is currently running.
  bool get _speechRecognitionActive => listener != null;

  /// Stops the microphone streaming; the transcript stays on screen.
  void _stopSpeechRecognition() {
    if (listener == null || terminating) {
      return;
    }
    listener!.cancel();
    listener = null;
    _recStart = null;
    whisper_streaming.terminate();
    terminating = true;
    _safeSetState(() {
      predict_result = "Please wait terminate.";
    });
  }

  void _processSamples(Uint8List samples) {
    // https://github.com/anarchuser/mic_stream/issues/94
    // The chunk may be an unaligned view into a larger buffer, so read
    // through ByteData instead of an Int16List view.
    final byteData = ByteData.sublistView(samples);
    final count = samples.length ~/ 2;
    final result = Float64List(count);
    for (var i = 0; i < count; i++) {
      result[i] = byteData.getInt16(i * 2, Endian.little) / 32738.0;
    }

    _pushWaveform(_peakBlocks(result, _micSampleRate));
    _safeSetState(() {}); // repaint waveform and REC time

    whisper_streaming.send(result, _micSampleRate);
  }

  void _ailiaAudioProcessingWhisper(
      String modelType, bool virtualMemory) async {
    ByteData data = await rootBundle.load("assets/demo.wav");
    final wav = await Wav.read(data.buffer.asUint8List());
    AudioProcessingWhisper whisper = AudioProcessingWhisper();
    List<String> modelList = whisper.getModelList(modelType);
    _safeSetState(() {
      _transcript.clear();
    });
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      await _displayDownloadEnd();
      File vad_file = File(await getModelPath(modelList[1]));
      File onnx_encoder_file = File(await getModelPath(modelList[3]));
      File onnx_decoder_file = File(await getModelPath(modelList[5]));
      int startTime = DateTime.now().millisecondsSinceEpoch;
      List<SpeechText> texts = await whisper.transcribe(wav, onnx_encoder_file,
          onnx_decoder_file, vad_file, selectedEnvId, modelType, virtualMemory);
      int endTime = DateTime.now().millisecondsSinceEpoch;
      _safeSetState(() {
        for (int i = 0; i < texts.length; i++) {
          _transcript.add(_formatTranscriptLine(texts[i]));
        }
        predict_result =
            "processing time : ${(endTime - startTime) / 1000} sec for ${(wav.channels[0].length / wav.samplesPerSecond)} sec audio.";
      });
      _scrollToBottom();
    });
  }

  void _ailiaAudioProcessingWhisperStreaming(
      String modelType, bool virtualMemory) async {
    List<String> modelList = whisper.getModelList(modelType);
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      await _displayDownloadEnd();

      _safeSetState(() {
        predict_result = "Please speak to mic.";
      });

      File vad_file = File(await getModelPath(modelList[1]));
      File onnx_encoder_file = File(await getModelPath(modelList[3]));
      File onnx_decoder_file = File(await getModelPath(modelList[5]));

      // The Stop button handles termination via _stopSpeechRecognition;
      // ignore a Run that lands while stopping or already recording.
      if (terminating || listener != null) {
        return;
      }

      _safeSetState(() {
        _transcript.clear();
      });

      String lang = "ja";
      await whisper_streaming.open(
          onnx_encoder_file,
          onnx_decoder_file,
          vad_file,
          selectedEnvId,
          modelType,
          lang,
          virtualMemory,
          _liveTranscribe,
          _intermediateCallback,
          _messageCallback,
          _finishCallback);
      if (Platform.isIOS) {
        await Permission.microphone.request();
      }

      try {
        stream = MicStream.microphone(
            audioSource: AudioSource.DEFAULT,
            sampleRate: _micSampleRate,
            channelConfig: ChannelConfig.CHANNEL_IN_MONO,
            audioFormat: AudioFormat.ENCODING_PCM_16BIT);
        listener = stream!.listen(_processSamples);
        _recStart = DateTime.now();
        // Update the Run button into a Stop button.
        _safeSetState(() {});
      } catch (e) {
        _showError("Microphone is not available: $e");
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
        _safeSetState(() {
          predict_result =
              "$text1 vs $text2 sim $sim1\n$text1 vs $text3 sim $sim2\n$profileText";
        });
      }, _displayDownloadProgress);
    }, _displayDownloadProgress);
  }

  void _ailiaObjectDetectionYoloX() async {
    final imData = await _loadInputEncodedBytes(widget.model.sampleAsset!);
    image = await decodeImageFromList(imData);
    _safeSetState(() {});

    final files = await _downloadModelFiles(imageModelFiles['yolox']!);
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

      _safeSetState(() {
        _rtBoxes = res;
        _rtCategories = yolox.category;
        predict_result = "$resultSubText\n$profileText";
      });
    } finally {
      yolox.close();
    }
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

      _safeSetState(() {
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

      _safeSetState(() {
        predict_result = "$targetText -> $outputText\n$profileText";
      });
    });
  }

  /// Runs one of the text-to-speech demos. The four models share the
  /// same download/synthesize/play flow and differ only in their model
  /// files and G2P dictionaries.
  void _runTextToSpeech(int modelType) {
    TextToSpeech textToSpeech = TextToSpeech();
    List<String> modelList = textToSpeech.getModelList(modelType);
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      await _displayDownloadEnd();

      final tacotron2 = modelType == TextToSpeech.MODEL_TYPE_TACOTRON2;
      String encoderFile =
          await getModelPath(tacotron2 ? "encoder.onnx" : "t2s_encoder.onnx");
      String decoderFile = await getModelPath(
          tacotron2 ? "decoder_iter.onnx" : "t2s_fsdec.onnx");
      String postnetFile =
          await getModelPath(tacotron2 ? "postnet.onnx" : "t2s_sdec.opt.onnx");
      String waveglowFile =
          await getModelPath(tacotron2 ? "waveglow.onnx" : "vits.onnx");
      String? sslFile = tacotron2 ? null : await getModelPath("cnhubert.onnx");

      String dicFolderOpenJtalk =
          await getModelPath("open_jtalk_dic_utf_8-1.11/");
      // The English and Chinese G2P dictionary files are downloaded flat
      // into the model root.
      String? dicFolderEn =
          modelType == TextToSpeech.MODEL_TYPE_GPT_SOVITS_EN ||
                  modelType == TextToSpeech.MODEL_TYPE_GPT_SOVITS_ZH
              ? await getModelPath("/")
              : null;
      String? dicFolderCn = modelType == TextToSpeech.MODEL_TYPE_GPT_SOVITS_ZH
          ? await getModelPath("/")
          : null;
      String targetText = _ttsTextController.text.trim();
      String outputPath = await getModelPath("temp$_runCounter.wav");

      int startTime = DateTime.now().millisecondsSinceEpoch;
      if (!await _runTtsGeneration(() => textToSpeech.inference(
          targetText,
          outputPath,
          encoderFile,
          decoderFile,
          postnetFile,
          waveglowFile,
          sslFile,
          dicFolderOpenJtalk,
          dicFolderEn,
          modelType,
          dicFolderG2PCn: dicFolderCn))) {
        return;
      }
      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      _safeSetState(() {
        predict_result = profileText;
        _lastTtsPath = outputPath;
      });
      _startPlaybackWaveform(outputPath);
    });
  }

  // ---------------------------------------------------------------------
  // LLM chat
  // ---------------------------------------------------------------------

  bool get _isChatModel => widget.model.isChat;

  /// Downloads and opens the chat model once; later calls are no-ops so
  /// the conversation continues on the same context.
  Future<void> _ensureChatModel() async {
    // ailia LLM has its own backend list; use the LLM selection.
    String selectedBackend = BackendState.instance.selectedLlmBackend.value;
    if (_chatLlm != null) {
      if (selectedBackend == _chatBackend) {
        return;
      }
      // Backend changed: reopen the model. The context cannot move
      // between backends, so the conversation starts over.
      _chatLlm!.close();
      _chatLlm = null;
      _safeSetState(() {
        _chatMessages.clear();
      });
    }
    await AiliaLicense.checkAndDownloadLicense();
    final llm = LargeLanguageModel();
    final modelList = llm.getModelList(widget.model.id);
    final url =
        "https://storage.googleapis.com/ailia-models/${modelList[0]}/${modelList[1]}";
    _displayDownloadBegin();
    final modelFile =
        await downloadModel(url, modelList[1], null, _displayDownloadProgress);
    await _displayDownloadEnd();
    if (modelFile == null) {
      throw Exception("Model download failed");
    }
    if (!mounted) {
      // The screen was closed during the download; do not load the model.
      return;
    }

    _safeSetState(() {
      _status = "Loading model with selected backend...";
    });
    llm.openWithBackendName(modelFile, selectedBackend);
    if (!mounted) {
      llm.close();
      return;
    }
    llm.setSystemPrompt(_systemPrompt);
    _chatLlm = llm;
    _chatBackend = selectedBackend;
    _safeSetState(() {
      _status = "";
      predict_result = "Model loaded. Enter a message to chat.";
    });
  }

  void _clearChat() {
    _safeSetState(() {
      _chatMessages.clear();
      predict_result = "";
    });
    _chatLlm?.resetHistory();
  }

  Future<void> _editSystemPrompt() async {
    final controller = TextEditingController(text: _systemPrompt);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('System prompt'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || result == _systemPrompt) {
      return;
    }
    _safeSetState(() {
      _systemPrompt = result;
      // Changing the prompt starts a fresh conversation.
      _chatMessages.clear();
    });
    _chatLlm?.resetHistory(newSystemPrompt: result);
  }

  Future<void> _sendChatMessage() async {
    final text = _chatTextController.text.trim();
    if (text.isEmpty || _chatGenerating) {
      return;
    }
    _safeSetState(() {
      _chatGenerating = true;
      _errorText = null;
      _chatTextController.clear();
      _chatMessages.add({'role': 'user', 'content': text});
    });
    _scrollToBottom();
    try {
      await _ensureChatModel();
      if (!mounted || _chatLlm == null) {
        return;
      }
      _safeSetState(() {
        _chatMessages.add({'role': 'assistant', 'content': ''});
      });
      int startTime = DateTime.now().millisecondsSinceEpoch;
      // Accumulate tokens and repaint at most once per frame instead of
      // rebuilding the screen per token.
      final reply = StringBuffer();
      int lastPaintMs = 0;
      void paintReply() {
        _safeSetState(() {
          _chatMessages.last['content'] = reply.toString();
        });
        _scrollToBottom();
      }

      await _chatLlm!.chatStream(text, (delta) {
        reply.write(delta);
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastPaintMs >= 33) {
          lastPaintMs = nowMs;
          paintReply();
        }
      }, shouldContinue: () => mounted);
      if (mounted) {
        paintReply();
      }
      int endTime = DateTime.now().millisecondsSinceEpoch;
      _safeSetState(() {
        predict_result =
            "processing time : ${(endTime - startTime) / 1000} sec";
      });
    } catch (e) {
      _showError("Inference Error: $e");
    } finally {
      _chatGenerating = false;
      if (mounted) {
        _safeSetState(() {});
      } else {
        // The screen was closed while streaming; dispose deferred the
        // close to us.
        _chatLlm?.close();
        _chatLlm = null;
      }
    }
  }

  void _ailiaLargeLanguageModelGemma3Multimodal() async {
    MultimodalLargeLanguageModel multimodalLLM = MultimodalLargeLanguageModel();
    List<String> modelList = multimodalLLM.getModelList();
    _displayDownloadBegin();
    downloadModelFromModelList(0, modelList, () async {
      try {
        String imagePath;
        if (_capturedPath != null) {
          imagePath = _capturedPath!;
        } else {
          _safeSetState(() {
            predict_result = "Downloading sample image...";
          });
          File imageFile = await MultimodalLargeLanguageModel.downloadFile(
              "https://storage.googleapis.com/ailia-models/misc/sample_image.jpg",
              await getModelPath("sample_image.jpg"));
          imagePath = imageFile.path;
        }

        Uint8List imageBytes = await File(imagePath).readAsBytes();
        // The captured frame is already shown as the frozen camera
        // preview; only show the sample image separately.
        image = _capturedPath == null
            ? await decodeImageFromList(imageBytes)
            : null;

        _safeSetState(() {
          predict_result = "Models downloaded. Ready for inference.";
        });

        await _displayDownloadEnd();

        await _performGemma3MultimodalInference(multimodalLLM, imagePath);
      } catch (e) {
        _showError(e);
      }
    });
  }

  Future<void> _performGemma3MultimodalInference(
      MultimodalLargeLanguageModel multimodalLLM, String imagePath) async {
    try {
      _safeSetState(() {
        predict_result = "Loading model with selected backend...";
      });

      File modelFile = File(await getModelPath("gemma-3-4b-it-Q4_K_M.gguf"));
      File mmprojFile =
          File(await getModelPath("gemma-3-4b-it-GGUF_mmproj-model-f16.gguf"));

      String inputText = _vlmQueryController.text.trim();

      int startTime = DateTime.now().millisecondsSinceEpoch;

      // ailia LLM has its own backend list; use the LLM selection.
      String selectedBackend = BackendState.instance.selectedLlmBackend.value;

      multimodalLLM.openWithBackendName(modelFile, mmprojFile, selectedBackend);
      multimodalLLM.setSystemPrompt("画像を2-3文で簡潔に説明してください。");
      String outputText = multimodalLLM.chatWithImage(inputText, imagePath);

      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText =
          "processing time : ${(endTime - startTime) / 1000} sec";

      _safeSetState(() {
        predict_result = "$outputText\n$profileText";
      });

      multimodalLLM.close();
    } catch (e) {
      _showError("Inference Error: $e");
    }
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  /// Width-constrained container used by all demo panels so the layout
  /// adapts to narrow windows.
  Widget _panel({required Widget child, EdgeInsetsGeometry? margin}) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 480),
      margin: margin ?? const EdgeInsets.only(top: 8),
      child: child,
    );
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  Widget _buildStatus() {
    if (_status.isEmpty) {
      return const SizedBox.shrink();
    }
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(_status)),
            ],
          ),
          if (_downloadProgress != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(value: _downloadProgress),
            ),
        ],
      ),
    );
  }

  Widget _buildError() {
    if (_errorText == null) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return _panel(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: scheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: SelectableText(
                _errorText!,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResult() {
    if (predict_result.isEmpty) {
      return const SizedBox.shrink();
    }
    return _panel(
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceVariant.withOpacity(0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: SelectableText(predict_result),
        ),
      ),
    );
  }

  Widget _buildImage(BuildContext context) {
    if (image != null) {
      double screenHeight = MediaQuery.of(context).size.height;
      double height = screenHeight * 0.45;
      double width = height * image!.width / image!.height;
      return Container(
        width: width,
        height: height,
        margin: const EdgeInsets.only(top: 12),
        child: Stack(
          fit: StackFit.expand,
          children: [
            CustomPaint(
              painter: ImageEditor(image: image!),
            ),
            if (_rtBoxes.isNotEmpty)
              CustomPaint(
                painter: CameraOverlayPainter(
                  boxes: _rtBoxes,
                  categories: _rtCategories,
                ),
              ),
          ],
        ),
      );
    } else {
      return const SizedBox.shrink();
    }
  }

  Widget _buildWaveform() {
    final micActive = _supportsMic && _inputSource == InputSource.mic;
    if (!micActive && _waveform.isEmpty) {
      return const SizedBox.shrink();
    }
    String recTime = '';
    if (_speechRecognitionActive && _recStart != null) {
      final elapsed = DateTime.now().difference(_recStart!);
      final minutes = (elapsed.inSeconds ~/ 60).toString().padLeft(2, '0');
      final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
      recTime = "$minutes:$seconds";
    }
    return _panel(
      child: Column(
        children: [
          if (_speechRecognitionActive)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Icon(Icons.fiber_manual_record,
                      color: Colors.red, size: 14),
                  const SizedBox(width: 4),
                  Text("REC $recTime"),
                ],
              ),
            ),
          Container(
            width: double.infinity,
            height: 100,
            decoration: BoxDecoration(
              border: Border.all(color: Theme.of(context).colorScheme.outline),
              borderRadius: BorderRadius.circular(8),
            ),
            child: CustomPaint(
              painter: WaveformPainter(
                samples: _waveform,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTtsTextField() {
    if (!widget.model.isTextToSpeech) {
      return const SizedBox.shrink();
    }
    return _panel(
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _ttsTextController,
              decoration: const InputDecoration(
                labelText: 'Text to speak',
                border: OutlineInputBorder(),
              ),
              minLines: 1,
              maxLines: 3,
            ),
          ),
          const SizedBox(width: 8),
          IconButton.filledTonal(
            tooltip: 'Replay last audio',
            onPressed: _lastTtsPath == null ? null : _replayTts,
            icon: const Icon(Icons.replay),
          ),
        ],
      ),
    );
  }

  /// Shows a generating status while [generate] runs. Returns false if
  /// the generation failed. The status text is given one frame to render
  /// because the synthesis itself blocks the UI isolate.
  Future<bool> _runTtsGeneration(Future<void> Function() generate) async {
    _safeSetState(() {
      _status = "Generating speech...";
    });
    await Future.delayed(const Duration(milliseconds: 50));
    try {
      await generate();
    } catch (e) {
      _showError(e);
      return false;
    }
    _safeSetState(() {
      _status = "";
    });
    return true;
  }

  Future<void> _replayTts() async {
    final path = _lastTtsPath;
    if (path == null) {
      return;
    }
    final player = AudioPlayer();
    await player.play(DeviceFileSource(path));
    _startPlaybackWaveform(path);
  }

  Widget _buildVlmQueryField() {
    if (!_isVlmModel) {
      return const SizedBox.shrink();
    }
    return _panel(
      child: TextField(
        controller: _vlmQueryController,
        decoration: const InputDecoration(
          labelText: 'Query',
          border: OutlineInputBorder(),
        ),
        minLines: 1,
        maxLines: 3,
      ),
    );
  }

  Widget _buildChatUi() {
    if (!_isChatModel) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    return _panel(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Edit system prompt',
                onPressed: _chatGenerating ? null : _editSystemPrompt,
                icon: const Icon(Icons.tune, size: 20),
              ),
              IconButton(
                tooltip: 'Clear conversation',
                onPressed: _chatGenerating || _chatMessages.isEmpty
                    ? null
                    : _clearChat,
                icon: const Icon(Icons.delete_sweep, size: 20),
              ),
            ],
          ),
          for (final message in _chatMessages)
            Align(
              alignment: message['role'] == 'user'
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                constraints: const BoxConstraints(maxWidth: 400),
                decoration: BoxDecoration(
                  color: message['role'] == 'user'
                      ? scheme.primaryContainer
                      : scheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(message['content'] ?? ''),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _chatTextController,
                  decoration: const InputDecoration(
                    labelText: 'Message',
                    border: OutlineInputBorder(),
                  ),
                  minLines: 1,
                  maxLines: 3,
                  onSubmitted: (_) => _sendChatMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _chatGenerating ? null : _sendChatMessage,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTranscript() {
    if (_transcript.isEmpty) {
      return const SizedBox.shrink();
    }
    return _panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Transcript', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              IconButton(
                tooltip: 'Copy transcript',
                onPressed: () {
                  Clipboard.setData(
                      ClipboardData(text: _transcript.join('\n')));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Transcript copied to clipboard.')));
                },
                icon: const Icon(Icons.copy, size: 20),
              ),
              IconButton(
                tooltip: 'Clear transcript',
                onPressed: _speechRecognitionActive
                    ? null
                    : () {
                        _safeSetState(() {
                          _transcript.clear();
                        });
                      },
                icon: const Icon(Icons.delete_sweep, size: 20),
              ),
            ],
          ),
          for (final line in _transcript)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SelectableText(line),
            ),
        ],
      ),
    );
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
                _safeSetState(() {
                  _virtualMemory = v;
                });
              },
            ),
          ),
          if (_inputSource == InputSource.mic)
            SizedBox(
              width: 320,
              child: SwitchListTile(
                dense: true,
                title: const Text('Live transcribe'),
                value: _liveTranscribe,
                // Applied when the next recognition starts.
                onChanged: _speechRecognitionActive
                    ? null
                    : (v) {
                        _safeSetState(() {
                          _liveTranscribe = v;
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
          _safeSetState(() {
            _macCameraController = controller;
          });
          final size = controller.args.size;
          if (size.width > 0 && size.height > 0) {
            _updateCameraAspect(size.width.toInt(), size.height.toInt());
          }
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
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 480),
      child: AspectRatio(
        aspectRatio: _cameraAspect,
        child: Stack(
          fit: StackFit.expand,
          children: [
            preview,
            if (frozen)
              GestureDetector(
                onTap: () {
                  _safeSetState(() {
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
                  frameImage: _rtFrameImage,
                  overlayImage: _rtOverlayImage,
                  label: _rtLabel,
                  showCenterMarker: widget.model.id == 'sam2',
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildRunButton() {
    // Chat demos run through their own send button.
    if (_isChatModel) {
      return const SizedBox.shrink();
    }
    final stopMode = _realtimeActive || _speechRecognitionActive;
    final busy = !stopMode && (_status.isNotEmpty || _chatGenerating);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: FilledButton.icon(
        style: FilledButton.styleFrom(
          minimumSize: const Size(160, 48),
        ),
        onPressed: busy
            ? null
            : () {
                if (_supportsRealtime) {
                  _toggleRealtime();
                  return;
                }
                if (_speechRecognitionActive) {
                  _stopSpeechRecognition();
                  return;
                }
                _runCounter++;
                _run();
              },
        icon: busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(stopMode ? Icons.stop : Icons.play_arrow),
        label: Text(stopMode
            ? 'Stop'
            : busy
                ? 'Working...'
                : 'Run'),
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
        controller: _scrollController,
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
                _buildWaveform(),
                _buildTtsTextField(),
                _buildVlmQueryField(),
                _buildImage(context),
                _buildChatUi(),
                _buildRunButton(),
                _buildStatus(),
                _buildError(),
                _buildResult(),
                _buildTranscript(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Scrolling microphone waveform: one vertical bar per amplitude block,
/// newest samples on the right.
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.samples,
    required this.color,
  });

  final List<double> samples;
  final Color color;

  @override
  void paint(Canvas canvas, ui.Size size) {
    final centerY = size.height / 2;
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.max(1, size.width / _DemoScreenState._waveformBlocks)
      ..strokeCap = StrokeCap.round;

    // Baseline
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      Paint()
        ..color = color.withOpacity(0.3)
        ..strokeWidth = 1,
    );

    final step = size.width / _DemoScreenState._waveformBlocks;
    final offset = _DemoScreenState._waveformBlocks - samples.length;
    for (int i = 0; i < samples.length; i++) {
      final x = (offset + i + 0.5) * step;
      final amp = samples[i].clamp(0.0, 1.0) * (size.height / 2 - 2);
      canvas.drawLine(
        Offset(x, centerY - math.max(amp, 0.5)),
        Offset(x, centerY + math.max(amp, 0.5)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) {
    return true;
  }
}

/// One camera frame as tightly packed RGB bytes, optionally with a
/// prebuilt RGBA copy for display.
class _CameraFrame {
  _CameraFrame(this.rgb, this.width, this.height, {this.rgba});

  final Uint8List rgb;
  final int width;
  final int height;
  final Uint8List? rgba;
}

/// Draws realtime inference results (bounding boxes, masks, labels)
/// on top of the live camera preview.
class CameraOverlayPainter extends CustomPainter {
  CameraOverlayPainter({
    required this.boxes,
    required this.categories,
    this.frameImage,
    this.overlayImage,
    this.label = '',
    this.showCenterMarker = false,
  });

  final List<AiliaDetectorObject> boxes;
  final List<String> categories;

  /// The processed camera frame, drawn opaquely under the results so the
  /// displayed image matches what the model actually saw.
  final ui.Image? frameImage;
  final ui.Image? overlayImage;
  final String label;

  /// Marks the segmentation point (image center) with a red dot.
  final bool showCenterMarker;

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
    final frame = frameImage;
    if (frame != null) {
      final src =
          Rect.fromLTWH(0, 0, frame.width.toDouble(), frame.height.toDouble());
      final dst = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawImageRect(frame, src, dst, Paint());
    }
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

    if (showCenterMarker) {
      final center = Offset(size.width / 2, size.height / 2);
      canvas.drawCircle(
        center,
        7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white,
      );
      canvas.drawCircle(center, 5, Paint()..color = Colors.red);
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
    final rect = Rect.fromLTWH(x, y, painter.width + 8, painter.height + 4);
    canvas.drawRect(rect, Paint()..color = bg.withOpacity(0.7));
    painter.paint(canvas, Offset(x + 4, y + 2));
  }

  @override
  bool shouldRepaint(CameraOverlayPainter oldDelegate) {
    return oldDelegate.boxes != boxes ||
        oldDelegate.frameImage != frameImage ||
        oldDelegate.overlayImage != overlayImage ||
        oldDelegate.label != label ||
        oldDelegate.showCenterMarker != showCenterMarker;
  }
}

class ImageEditor extends CustomPainter {
  ImageEditor({
    required this.image,
  });

  ui.Image image;

  @override
  void paint(Canvas canvas, ui.Size size) {
    final src =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, src, dst, Paint());
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) {
    return false;
  }
}
