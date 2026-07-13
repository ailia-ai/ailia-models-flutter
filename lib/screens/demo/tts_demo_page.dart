import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

import '../../model_catalog.dart';
import '../../text_to_speech/text_to_speech.dart';
import '../../utils/download_model.dart';
import 'demo_session.dart';
import 'waveform_view.dart';

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

  // Text spoken by the text-to-speech demos.
  late final TextEditingController _textController =
      TextEditingController(text: widget.model.defaultInputText ?? '');

  // Last synthesized audio, replayable without re-synthesizing.
  String? _lastTtsPath;
  int _runCounter = 0;

  int get _modelType {
    switch (widget.model.id) {
      case "gpt-sovits-ja":
        return TextToSpeech.MODEL_TYPE_GPT_SOVITS_JA;
      case "gpt-sovits-en":
        return TextToSpeech.MODEL_TYPE_GPT_SOVITS_EN;
      case "gpt-sovits-zh":
        return TextToSpeech.MODEL_TYPE_GPT_SOVITS_ZH;
      default:
        return TextToSpeech.MODEL_TYPE_TACOTRON2;
    }
  }

  @override
  void dispose() {
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

  /// Runs one of the text-to-speech demos. The four models share the
  /// same download/synthesize/play flow and differ only in their model
  /// files and G2P dictionaries.
  Future<void> _runTextToSpeech() async {
    final modelType = _modelType;
    TextToSpeech textToSpeech = TextToSpeech();
    List<String> modelList = textToSpeech.getModelList(modelType);
    if (!await _session.downloadModelList(modelList)) {
      return;
    }

    final tacotron2 = modelType == TextToSpeech.MODEL_TYPE_TACOTRON2;
    String encoderFile =
        await getModelPath(tacotron2 ? "encoder.onnx" : "t2s_encoder.onnx");
    String decoderFile =
        await getModelPath(tacotron2 ? "decoder_iter.onnx" : "t2s_fsdec.onnx");
    String postnetFile =
        await getModelPath(tacotron2 ? "postnet.onnx" : "t2s_sdec.opt.onnx");
    String waveglowFile =
        await getModelPath(tacotron2 ? "waveglow.onnx" : "vits.onnx");
    String? sslFile = tacotron2 ? null : await getModelPath("cnhubert.onnx");

    String dicFolderOpenJtalk =
        await getModelPath("open_jtalk_dic_utf_8-1.11/");
    // The English and Chinese G2P dictionary files are downloaded flat
    // into the model root.
    String? dicFolderEn = modelType == TextToSpeech.MODEL_TYPE_GPT_SOVITS_EN ||
            modelType == TextToSpeech.MODEL_TYPE_GPT_SOVITS_ZH
        ? await getModelPath("/")
        : null;
    String? dicFolderCn = modelType == TextToSpeech.MODEL_TYPE_GPT_SOVITS_ZH
        ? await getModelPath("/")
        : null;
    String targetText = _textController.text.trim();
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

  @override
  Widget build(BuildContext context) {
    return DemoPageScaffold(
      model: widget.model,
      session: _session,
      children: [
        WaveformView(controller: _waveform),
        _buildTextField(),
        DemoRunButton(session: _session, onPressed: _run),
      ],
    );
  }
}
