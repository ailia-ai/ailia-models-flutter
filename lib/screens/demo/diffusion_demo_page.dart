import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../../backend_state.dart';
import '../../diffusion/sdxl/sdxl.dart';
import '../../model_catalog.dart';
import '../../utils/download_model.dart';
import '../../utils/image_util.dart';
import 'camera_input.dart';
import 'demo_session.dart';
import 'still_image.dart';

/// Image generation demo (Stable Diffusion XL): text2img renders the
/// prompt from noise, img2img repaints the sample image (or a camera
/// still) following the prompt.
class DiffusionDemoPage extends StatefulWidget {
  const DiffusionDemoPage({super.key, required this.model});

  final ModelInfo model;

  @override
  State<DiffusionDemoPage> createState() => _DiffusionDemoPageState();
}

class _DiffusionDemoPageState extends State<DiffusionDemoPage>
    with SafeSetStateMixin {
  final DemoSession _session = DemoSession();
  final CameraInput _camera = CameraInput();

  // The img2img default follows the Python sample's README: the prompt
  // describes the whole target image (the bundled astronaut sample
  // with the spacesuit repainted red), not just the edit.
  static const String _txt2imgPrompt =
      'Astronaut in a jungle, cold color palette, muted colors, detailed, 8k';
  static const String _img2imgPrompt =
      'Astronaut in a red spacesuit standing in a jungle, '
      'cold color palette, muted colors, detailed, 8k';

  final TextEditingController _promptController =
      TextEditingController(text: _txt2imgPrompt);
  final TextEditingController _stepsController =
      TextEditingController(text: '20');
  final TextEditingController _guidanceController =
      TextEditingController(text: '5.0');

  bool _img2img = false;
  int _resolution = 512;
  double _strength = 0.85;
  bool _previewEachStep = false;

  bool _useCamera = false;
  ui.Image? _image;

  // Kept open across Runs so a repeated Run skips the multi-GB model
  // load. Released when leaving the page or changing the backend.
  StableDiffusionXL? _sdxl;

  @override
  void initState() {
    super.initState();
    BackendState.instance.selectedEnvId.addListener(_onEnvChanged);
    _loadSampleImage();
  }

  @override
  void dispose() {
    BackendState.instance.selectedEnvId.removeListener(_onEnvChanged);
    _releaseModel();
    _promptController.dispose();
    _stepsController.dispose();
    _guidanceController.dispose();
    _camera.dispose();
    _session.dispose();
    super.dispose();
  }

  /// The resident models were opened with the previous backend, so a
  /// backend change invalidates them; the next Run reopens them.
  void _onEnvChanged() {
    _releaseModel();
  }

  void _releaseModel() {
    _sdxl?.close();
    _sdxl = null;
  }

  /// Shows the bundled img2img sample image (img2img mode only; in
  /// text2img mode nothing is shown before the first run).
  Future<void> _loadSampleImage() async {
    if (!_img2img || _useCamera) {
      safeSetState(() {
        _image = null;
      });
      return;
    }
    final data = await rootBundle.load(widget.model.sampleAsset!);
    final loaded = await decodeImageFromList(data.buffer.asUint8List());
    safeSetState(() {
      _image = loaded;
    });
  }

  void _switchMode(bool img2img) {
    // Swap the mode's default prompt in, but never overwrite a prompt
    // the user has edited.
    final defaults = {_txt2imgPrompt, _img2imgPrompt};
    if (defaults.contains(_promptController.text.trim())) {
      _promptController.text = img2img ? _img2imgPrompt : _txt2imgPrompt;
    }
    safeSetState(() {
      _img2img = img2img;
      _image = null;
    });
    if (!img2img && _useCamera) {
      _switchSource(false);
    } else {
      _loadSampleImage();
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

  /// The img2img input, center-cropped to a square and resized to the
  /// selected resolution (a multiple of 64, as the pipeline requires).
  Future<img.Image> _loadInputImage() async {
    img.Image? input;
    final capturedPath = _camera.capturedPath;
    if (_useCamera && capturedPath != null) {
      input = img.decodeImage(await File(capturedPath).readAsBytes());
    } else {
      final data = await rootBundle.load(widget.model.sampleAsset!);
      input = img.decodeImage(data.buffer.asUint8List());
    }
    if (input == null) {
      throw Exception('Failed to load the input image.');
    }
    return img.copyResizeCropSquare(input, size: _resolution);
  }

  Future<void> _onStatus(String status) async {
    _session.setStatus(status);
    // Let the status render before the next call blocks the UI isolate.
    await Future.delayed(const Duration(milliseconds: 50));
  }

  /// Per-step progress: the status line, the progress bar, and (when
  /// preview is enabled) the current denoised estimate as the image.
  Future<void> _onStep(
      int completedSteps, int totalSteps, img.Image? preview) async {
    if (preview != null) {
      final previewImage = await imageToUiImage(preview);
      safeSetState(() {
        _image = previewImage;
      });
    }
    _session.status = completedSteps < totalSteps
        ? 'Sampling step ${completedSteps + 1}/$totalSteps...'
        : 'Sampling finished';
    _session.downloadProgress = completedSteps / totalSteps;
    _session.notifyListeners();
    // Let the progress render before the next step blocks the UI isolate.
    await Future.delayed(const Duration(milliseconds: 50));
  }

  Future<void> _run() => _session.run(() async {
        final prompt = _promptController.text.trim();
        if (prompt.isEmpty) {
          _session.showResult('Enter a prompt.');
          return;
        }
        final steps = (int.tryParse(_stepsController.text) ?? 20).clamp(1, 100);
        final guidanceScale =
            double.tryParse(_guidanceController.text) ?? 5.0;

        if (_img2img && _useCamera) {
          // The captured frame freezes the preview; inference uses it.
          await _camera.captureStill();
        } else {
          _camera.clearCapture();
        }

        final modelList = StableDiffusionXL.getModelList(img2img: _img2img);
        if (!await _session.downloadModelList(modelList)) {
          return;
        }

        if (_sdxl == null) {
          final sdxl = StableDiffusionXL();
          sdxl.open(await getModelPath(''), envId: selectedEnvId);
          _sdxl = sdxl;
        }
        final sdxl = _sdxl!;
        try {
          final startTime = DateTime.now().millisecondsSinceEpoch;
          img.Image result;
          if (_img2img) {
            final input = await _loadInputImage();
            result = await sdxl.img2img(
              image: input,
              prompt: prompt,
              steps: steps,
              guidanceScale: guidanceScale,
              strength: _strength,
              previewEachStep: _previewEachStep,
              onStep: _onStep,
              onStatus: _onStatus,
            );
          } else {
            result = await sdxl.txt2img(
              prompt: prompt,
              width: _resolution,
              height: _resolution,
              steps: steps,
              guidanceScale: guidanceScale,
              previewEachStep: _previewEachStep,
              onStep: _onStep,
              onStatus: _onStatus,
            );
          }
          final endTime = DateTime.now().millisecondsSinceEpoch;

          final resultImage = await imageToUiImage(result);
          safeSetState(() {
            _image = resultImage;
          });
          _session.clearStatus();
          _session.showResult(
              'processing time : ${endTime - startTime} ms ($steps steps)');
        } catch (e) {
          // A failed run may leave a model in a bad state; reopen on
          // the next Run.
          _releaseModel();
          rethrow;
        }
      });

  Widget _buildModeSelector() {
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(
            value: false,
            label: Text('Text to Image'),
            icon: Icon(Icons.notes)),
        ButtonSegment(
            value: true,
            label: Text('Image to Image'),
            icon: Icon(Icons.image)),
      ],
      selected: {_img2img},
      onSelectionChanged: (selection) {
        _switchMode(selection.first);
      },
    );
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

  Widget _buildResolutionSelector() {
    return SegmentedButton<int>(
      segments: const [
        ButtonSegment(value: 512, label: Text('512x512 (fast)')),
        ButtonSegment(value: 1024, label: Text('1024x1024 (quality)')),
      ],
      selected: {_resolution},
      onSelectionChanged: (selection) {
        safeSetState(() {
          _resolution = selection.first;
        });
      },
    );
  }

  Widget _buildPromptField() {
    return DemoPanel(
      child: TextField(
        controller: _promptController,
        decoration: const InputDecoration(
          labelText: 'Prompt',
          border: OutlineInputBorder(),
        ),
        minLines: 1,
        maxLines: 3,
      ),
    );
  }

  Widget _buildParameterFields() {
    return DemoPanel(
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _stepsController,
              decoration: const InputDecoration(
                labelText: 'Steps',
                border: OutlineInputBorder(),
              ),
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _guidanceController,
              decoration: const InputDecoration(
                labelText: 'Guidance scale',
                border: OutlineInputBorder(),
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
            ),
          ),
        ],
      ),
    );
  }

  /// Decodes the denoised estimate with the VAE after every sampling
  /// step and shows it as the image (slower, but shows the picture
  /// forming).
  Widget _buildPreviewSwitch() {
    return DemoPanel(
      child: SwitchListTile(
        title: const Text('Preview each step'),
        subtitle: const Text('VAE decode per step (slower)'),
        contentPadding: EdgeInsets.zero,
        value: _previewEachStep,
        onChanged: (value) {
          safeSetState(() {
            _previewEachStep = value;
          });
        },
      ),
    );
  }

  /// img2img strength: the fraction of the schedule that is run, so
  /// higher values keep less of the input image.
  Widget _buildStrengthSlider() {
    return DemoPanel(
      child: Row(
        children: [
          Text('Strength ${_strength.toStringAsFixed(2)}'),
          Expanded(
            child: Slider(
              value: _strength,
              min: 0.1,
              max: 1.0,
              divisions: 18,
              onChanged: (value) {
                safeSetState(() {
                  _strength = value;
                });
              },
            ),
          ),
        ],
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
        _buildModeSelector(),
        const SizedBox(height: 8),
        _buildResolutionSelector(),
        if (_img2img && CameraInput.supported) ...[
          const SizedBox(height: 8),
          _buildSourceSelector(),
        ],
        if (_img2img && _useCamera) CameraPreviewView(input: _camera),
        _buildPromptField(),
        _buildParameterFields(),
        if (_img2img) _buildStrengthSlider(),
        _buildPreviewSwitch(),
        _buildImage(context),
        DemoRunButton(session: _session, onPressed: _run),
      ],
    );
  }
}
