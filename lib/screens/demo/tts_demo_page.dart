import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../model_catalog.dart';
import '../../text_to_speech/text_to_speech.dart';
import '../../utils/download_model.dart';
import 'demo_session.dart';
import 'waveform_view.dart';

/// GPT-SoVITS V2Pro variants selectable in the demo.
enum _V2ProVariant {
  normal('Normal', TextToSpeech.MODEL_TYPE_GPT_SOVITS_V2_PRO_JA),
  distillSmall('Distill Small',
      TextToSpeech.MODEL_TYPE_GPT_SOVITS_V2_PRO_DISTILL_SMALL_JA),
  distillBase('Distill Base',
      TextToSpeech.MODEL_TYPE_GPT_SOVITS_V2_PRO_DISTILL_BASE_JA);

  const _V2ProVariant(this.label, this.modelType);
  final String label;
  final int modelType;
}

/// Text-to-speech demos (Tacotron2 and GPT-SoVITS). The synthesized
/// audio plays immediately and streams into the waveform display; the
/// last output can be replayed without re-synthesizing.
class TtsDemoPage extends StatefulWidget {
  const TtsDemoPage({super.key, required this.model});

  final ModelInfo model;

  @override
  State<TtsDemoPage> createState() => _TtsDemoPageState();
}

class _TtsDemoPageState extends State<TtsDemoPage> with SafeSetStateMixin {
  final DemoSession _session = DemoSession();
  final WaveformController _waveform = WaveformController();

  // Kept open across runs so the second and later syntheses skip the
  // model load and SetReference.
  final TextToSpeech _tts = TextToSpeech();

  // Text spoken by the text-to-speech demos.
  late final TextEditingController _textController =
      TextEditingController(text: widget.model.defaultInputText ?? '');

  // Last synthesized audio, replayable without re-synthesizing.
  String? _lastTtsPath;
  int _runCounter = 0;

  bool get _isV2Pro => widget.model.id == "gpt-sovits-v2pro-ja";
  _V2ProVariant _v2ProVariant = _V2ProVariant.normal;

  int get _modelType {
    switch (widget.model.id) {
      case "gpt-sovits-ja":
        return TextToSpeech.MODEL_TYPE_GPT_SOVITS_JA;
      case "gpt-sovits-en":
        return TextToSpeech.MODEL_TYPE_GPT_SOVITS_EN;
      case "gpt-sovits-zh":
        return TextToSpeech.MODEL_TYPE_GPT_SOVITS_ZH;
      case "gpt-sovits-v2pro-ja":
        return _v2ProVariant.modelType;
      default:
        return TextToSpeech.MODEL_TYPE_TACOTRON2;
    }
  }

  @override
  void dispose() {
    _tts.close();
    _textController.dispose();
    _waveform.dispose();
    _session.dispose();
    super.dispose();
  }

  Future<void> _run() {
    if (_textController.text.trim().isEmpty) {
      _session.showResult('Please enter text to speak.');
      return Future.value();
    }
    _runCounter++;
    return _session.run(_runTextToSpeech);
  }

  /// Runs one of the text-to-speech demos. The models share the same
  /// download/synthesize/play flow; TextToSpeech resolves the model
  /// files and G2P dictionaries from the model type and keeps the
  /// instance open so later runs skip the load and SetReference.
  Future<void> _runTextToSpeech() async {
    final modelType = _modelType;
    List<String> modelList = _tts.getModelList(modelType);
    if (!await _session.downloadModelList(modelList)) {
      return;
    }

    String targetText = _textController.text.trim();
    String outputPath = await getModelPath("temp$_runCounter.wav");

    int startTime = DateTime.now().millisecondsSinceEpoch;
    if (!await _runTtsGeneration(
        () => _tts.inference(targetText, outputPath, modelType))) {
      return;
    }
    int endTime = DateTime.now().millisecondsSinceEpoch;
    String profileText =
        "processing time : ${endTime - startTime} ms";

    safeSetState(() {
      _lastTtsPath = outputPath;
    });
    _session.showResult(profileText);
    _waveform.playFromWav(outputPath);
  }

  /// Shows a generating status while [generate] runs. Returns false if
  /// the generation failed. The status text is given one frame to render
  /// because the synthesis itself blocks the UI isolate.
  Future<bool> _runTtsGeneration(Future<void> Function() generate) async {
    _session.setStatus("Generating speech...");
    await Future.delayed(const Duration(milliseconds: 50));
    try {
      await generate();
    } catch (e) {
      _session.showError(e);
      return false;
    }
    _session.clearStatus();
    return true;
  }

  Future<void> _replayTts() async {
    final path = _lastTtsPath;
    if (path == null) {
      return;
    }
    final player = AudioPlayer();
    await player.play(DeviceFileSource(path));
    _waveform.playFromWav(path);
  }

  Widget _buildTextField() {
    return DemoPanel(
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _textController,
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

  /// Normal / Distill Small / Distill Base selector for GPT-SoVITS V2Pro.
  /// A change reopens the model on the next run.
  Widget _buildV2ProSelector() {
    return ListenableBuilder(
      listenable: _session,
      builder: (context, _) => SegmentedButton<_V2ProVariant>(
        segments: [
          for (final variant in _V2ProVariant.values)
            ButtonSegment(value: variant, label: Text(variant.label)),
        ],
        selected: {_v2ProVariant},
        onSelectionChanged: _session.processing
            ? null
            : (selection) => safeSetState(() {
                  _v2ProVariant = selection.first;
                }),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DemoPageScaffold(
      model: widget.model,
      session: _session,
      children: [
        if (_isV2Pro) ...[
          _buildV2ProSelector(),
          const SizedBox(height: 8),
        ],
        WaveformView(controller: _waveform),
        _buildTextField(),
        DemoRunButton(session: _session, onPressed: _run),
      ],
    );
  }
}
