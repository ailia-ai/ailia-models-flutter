import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../backend_state.dart';
import '../../large_language_model/multimodal_large_language_model.dart';
import '../../model_catalog.dart';
import '../../utils/download_model.dart';
import 'camera_input.dart';
import 'demo_session.dart';
import 'still_image.dart';

/// VLM (image + text) demo: describes the sample image or a
/// still frame captured from the camera.
class VlmDemoPage extends StatefulWidget {
  const VlmDemoPage({super.key, required this.model});

  final ModelInfo model;

  @override
  State<VlmDemoPage> createState() => _VlmDemoPageState();
}

class _VlmDemoPageState extends State<VlmDemoPage> with SafeSetStateMixin {
  final DemoSession _session = DemoSession();
  final CameraInput _camera = CameraInput();
  final MultimodalLargeLanguageModel _vlm = MultimodalLargeLanguageModel();

  // Query for the multimodal (image + text) LLM demo.
  final TextEditingController _queryController =
      TextEditingController(text: 'この画像を簡潔に説明してください。');

  bool _useCamera = false;
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _loadSampleImage();
    // Automation hook: AILIA_AUTO_RUN=1 presses Run once the page is up
    // and reports the outcome on stdout (used together with
    // AILIA_OPEN_MODEL and AILIA_SCREENSHOT).
    if (Platform.environment['AILIA_AUTO_RUN'] == '1') {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await _run();
        debugPrint('AILIA_AUTO_RUN result: ${_session.result}');
        debugPrint('AILIA_AUTO_RUN error: ${_session.errorText}');
      });
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    _camera.dispose();
    // Stop the inference isolate if a run is still in flight.
    _vlm.cancel();
    _session.dispose();
    super.dispose();
  }

  /// Shows the demo's sample image (downloaded, not bundled) next to
  /// the query box before the first run.
  Future<void> _loadSampleImage() async {
    try {
      final imageFile = await MultimodalLargeLanguageModel.downloadFile(
          "https://storage.googleapis.com/ailia-models/misc/sample_image.jpg",
          await getModelPath("sample_image.jpg"));
      final loaded = await decodeImageFromList(await imageFile.readAsBytes());
      safeSetState(() {
        _image = loaded;
      });
    } catch (_) {
      // The image appears after the model download instead.
    }
  }

  Future<void> _switchSource(bool useCamera) async {
    if (useCamera) {
      safeSetState(() {
        _useCamera = true;
        _image = null;
      });
      await _camera.open();
    } else {
      await _camera.close();
      safeSetState(() {
        _useCamera = false;
      });
      _loadSampleImage();
    }
  }

  Future<void> _run() => _session.run(() async {
        if (_useCamera) {
          // The captured frame freezes the preview; inference uses it.
          await _camera.captureStill();
        } else {
          _camera.clearCapture();
        }
        await _runMultimodal();
      });

  Future<void> _runMultimodal() async {
    try {
      final backend = BackendState.instance.selectedLlmBackend.value;
      final modelList = _vlm.getModelList(widget.model.id, backend);
      if (!await _session.downloadModelList(modelList) || !mounted) {
        return;
      }
      String imagePath;
      final capturedPath = _camera.capturedPath;
      if (capturedPath != null) {
        imagePath = capturedPath;
      } else {
        _session.showResult("Downloading sample image...");
        File imageFile = await MultimodalLargeLanguageModel.downloadFile(
            "https://storage.googleapis.com/ailia-models/misc/sample_image.jpg",
            await getModelPath("sample_image.jpg"));
        imagePath = imageFile.path;
      }

      Uint8List imageBytes = await File(imagePath).readAsBytes();
      // The captured frame is already shown as the frozen camera
      // preview; only show the sample image separately.
      final loaded =
          capturedPath == null ? await decodeImageFromList(imageBytes) : null;
      safeSetState(() {
        _image = loaded;
      });

      _session.showResult("Models downloaded. Ready for inference.");
      _session.clearStatus();
      await Future.delayed(const Duration(milliseconds: 100));

      if (!mounted) return;
      await _performInference(imagePath, modelList, backend);
    } catch (e) {
      _session.showError(e);
    }
  }

  Future<void> _performInference(
      String imagePath, List<String> modelList, String selectedBackend) async {
    try {
      _session.showResult('Preparing image...');

      final type = widget.model.id;
      File modelFile = File(await getModelPath(modelList[1]));
      File mmprojFile = File(await getModelPath(modelList[3]));
      if (!mounted) return;

      String inputText = _queryController.text.trim();

      int startTime = DateTime.now().millisecondsSinceEpoch;

      // Generation runs in an isolate; stream tokens into the result
      // panel, repainting at most once per frame.
      final reply = StringBuffer();
      int lastPaintMs = 0;
      String outputText = await _vlm.chatWithImageIsolate(
        model: modelFile,
        mmproj: mmprojFile,
        backend: selectedBackend,
        nCtx: MultimodalLargeLanguageModel.contextSize(
            type, modelFile.path, selectedBackend),
        systemPrompt: "画像を2-3文で簡潔に説明してください。",
        inputText: inputText,
        imagePath: imagePath,
        onModelLoading: () =>
            _session.showResult('Loading model with selected backend...'),
        onModelLoaded: () => _session.showResult('Image Processing...'),
        onDelta: (delta) {
          reply.write(delta);
          final nowMs = DateTime.now().millisecondsSinceEpoch;
          if (nowMs - lastPaintMs >= 33) {
            lastPaintMs = nowMs;
            _session.showResult(reply.toString());
          }
        },
      );

      int endTime = DateTime.now().millisecondsSinceEpoch;
      String profileText = "processing time : ${endTime - startTime} ms";

      _session.showResult("$outputText\n$profileText");
    } catch (e) {
      _session.showError("Inference Error: $e");
    }
  }

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
          CameraDeviceSelector(input: _camera),
        ],
      ],
    );
  }

  Widget _buildQueryField() {
    return DemoPanel(
      child: TextField(
        controller: _queryController,
        decoration: const InputDecoration(
          labelText: 'Query',
          border: OutlineInputBorder(),
        ),
        minLines: 1,
        maxLines: 3,
      ),
    );
  }

  Widget _buildImage(BuildContext context) {
    final image = _image;
    if (image == null) {
      return const SizedBox.shrink();
    }
    return StillImageBox(image: image);
  }

  @override
  Widget build(BuildContext context) {
    return DemoPageScaffold(
      model: widget.model,
      session: _session,
      children: [
        if (CameraInput.supported) _buildSourceSelector(),
        const SizedBox(height: 8),
        if (_useCamera) CameraPreviewView(input: _camera),
        _buildQueryField(),
        _buildImage(context),
        DemoRunButton(session: _session, onPressed: _run),
      ],
    );
  }
}
