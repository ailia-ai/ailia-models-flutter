import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:ailia_speech/ailia_speech_model.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:record/record.dart';
import 'package:wav/wav.dart';

import '../../audio_processing/whisper.dart';
import '../../audio_processing/whisper_streaming.dart';
import '../../model_catalog.dart';
import '../../utils/download_model.dart';
import 'demo_session.dart';
import 'transcript_view.dart';
import 'waveform_view.dart';

/// Speech-to-text demos (Whisper / SenseVoice): one-shot transcription
/// of the sample audio, or streaming recognition from the microphone
/// with a meeting-minutes style transcript.
class SttDemoPage extends StatefulWidget {
  const SttDemoPage({super.key, required this.model});

  final ModelInfo model;

  @override
  State<SttDemoPage> createState() => _SttDemoPageState();
}

class _SttDemoPageState extends State<SttDemoPage> with SafeSetStateMixin {
  final DemoSession _session = DemoSession();
  final WaveformController _waveform = WaveformController();
  final ScrollController _scrollController = ScrollController();

  // Meeting-minutes style transcript of speech recognition results.
  final List<String> _transcript = [];

  bool _useMic = false;
  bool _virtualMemory = false;
  bool _liveTranscribe = false;

  final AudioProcessingWhisperStreaming _whisperStreaming =
      AudioProcessingWhisperStreaming();
  AudioRecorder? _micRecorder;
  StreamSubscription? _listener;
  bool _terminating = false;

  // Recording start time shown next to the mic waveform.
  DateTime? _recStart;

  // The record package resamples to the requested rate on every
  // platform; use the whisper native rate directly.
  final int _micSampleRate = 16000;

  /// Whether microphone speech recognition is currently running.
  bool get _recognitionActive => _listener != null;

  @override
  void dispose() {
    // Stop the speech recognition isolate; its finish callback closes it.
    if (_listener != null) {
      _listener!.cancel();
      _listener = null;
      _whisperStreaming.terminate();
    }
    _stopMicRecorder();
    _waveform.dispose();
    _scrollController.dispose();
    _session.dispose();
    super.dispose();
  }

  void _switchSource(bool useMic) {
    _stopRecognition();
    safeSetState(() {
      _useMic = useMic;
      _waveform.clear();
    });
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  // ---------------------------------------------------------------------
  // Microphone streaming recognition
  // ---------------------------------------------------------------------

  void _stopMicRecorder() {
    final recorder = _micRecorder;
    _micRecorder = null;
    if (recorder != null) {
      recorder.stop().then((_) => recorder.dispose()).catchError((_) {});
    }
  }

  /// Stops the microphone streaming; the transcript stays on screen.
  void _stopRecognition() {
    if (_listener == null || _terminating) {
      return;
    }
    _listener!.cancel();
    _stopMicRecorder();
    _whisperStreaming.terminate();
    _terminating = true;
    // Rebuild so the Stop button returns to Run; without this the page
    // only repaints when new transcript text happens to arrive.
    safeSetState(() {
      _listener = null;
      _recStart = null;
    });
    _session.showResult("Please wait terminate.");
  }

  void _intermediateCallback(List<SpeechText> text) {
    _session.showResult("${text[0].text}...");
  }

  void _messageCallback(List<SpeechText> text) {
    safeSetState(() {
      for (int i = 0; i < text.length; i++) {
        _transcript.add(_formatTranscriptLine(text[i]));
      }
    });
    _session.showResult("");
    _scrollToBottom();
  }

  void _finishCallback() {
    _whisperStreaming.close();
    _session.showResult("Complete.");
    _terminating = false;
  }

  void _processSamples(Uint8List samples) {
    // The chunk may be an unaligned view into a larger buffer, so read
    // through ByteData instead of an Int16List view.
    final byteData = ByteData.sublistView(samples);
    final count = samples.length ~/ 2;
    final result = Float64List(count);
    for (var i = 0; i < count; i++) {
      result[i] = byteData.getInt16(i * 2, Endian.little) / 32738.0;
    }

    // Repaints the waveform and the REC time.
    _waveform.push(WaveformController.peakBlocks(result, _micSampleRate));

    _whisperStreaming.send(result, _micSampleRate);
  }

  Future<void> _runStreaming() async {
    List<String> modelList =
        AudioProcessingWhisper().getModelList(widget.model.id);
    if (!await _session.downloadModelList(modelList)) {
      return;
    }

    _session.showResult("Please speak to mic.");

    File vadFile = File(await getModelPath(modelList[1]));
    File onnxEncoderFile = File(await getModelPath(modelList[3]));
    File onnxDecoderFile = File(await getModelPath(modelList[5]));

    // The Stop button handles termination via _stopRecognition; ignore
    // a Run that lands while stopping or already recording.
    if (_terminating || _listener != null) {
      return;
    }

    safeSetState(() {
      _transcript.clear();
    });

    String lang = "ja";
    await _whisperStreaming.open(
        onnxEncoderFile,
        onnxDecoderFile,
        vadFile,
        selectedEnvId,
        widget.model.id,
        lang,
        _virtualMemory,
        _liveTranscribe,
        _intermediateCallback,
        _messageCallback,
        _finishCallback);
    final recorder = AudioRecorder();
    try {
      // Asks for the microphone permission where required (iOS/Android).
      if (!await recorder.hasPermission()) {
        recorder.dispose();
        _session.showError("Microphone permission denied.");
        return;
      }
      final micStream = await recorder.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _micSampleRate,
        numChannels: 1,
      ));
      _micRecorder = recorder;
      _listener = micStream.listen(_processSamples);
      _recStart = DateTime.now();
      // Update the Run button into a Stop button.
      safeSetState(() {});
    } catch (e) {
      recorder.dispose();
      _session.showError("Microphone is not available: $e");
    }
  }

  // ---------------------------------------------------------------------
  // One-shot transcription of the sample audio
  // ---------------------------------------------------------------------

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

  Future<void> _runFile() async {
    ByteData data = await rootBundle.load("assets/demo.wav");
    final wav = Wav.read(data.buffer.asUint8List());
    AudioProcessingWhisper whisper = AudioProcessingWhisper();
    List<String> modelList = whisper.getModelList(widget.model.id);
    safeSetState(() {
      _transcript.clear();
    });
    if (!await _session.downloadModelList(modelList)) {
      return;
    }
    File vadFile = File(await getModelPath(modelList[1]));
    File onnxEncoderFile = File(await getModelPath(modelList[3]));
    File onnxDecoderFile = File(await getModelPath(modelList[5]));
    int startTime = DateTime.now().millisecondsSinceEpoch;
    List<SpeechText> texts = await whisper.transcribe(
        wav,
        onnxEncoderFile,
        onnxDecoderFile,
        vadFile,
        selectedEnvId,
        widget.model.id,
        _virtualMemory);
    int endTime = DateTime.now().millisecondsSinceEpoch;
    safeSetState(() {
      for (int i = 0; i < texts.length; i++) {
        _transcript.add(_formatTranscriptLine(texts[i]));
      }
    });
    _session.showResult(
        "processing time : ${endTime - startTime} ms for ${(wav.channels[0].length / wav.samplesPerSecond)} sec audio.");
    _scrollToBottom();
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  Widget _buildSourceSelector() {
    return Column(
      children: [
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(
                value: false,
                label: Text('Audio File'),
                icon: Icon(Icons.audio_file)),
            ButtonSegment(
                value: true, label: Text('Microphone'), icon: Icon(Icons.mic)),
          ],
          selected: {_useMic},
          onSelectionChanged: (selection) {
            _switchSource(selection.first);
          },
        ),
        SizedBox(
          width: 320,
          child: SwitchListTile(
            dense: true,
            title: const Text('Use virtual memory'),
            value: _virtualMemory,
            onChanged: (v) {
              safeSetState(() {
                _virtualMemory = v;
              });
            },
          ),
        ),
        if (_useMic)
          SizedBox(
            width: 320,
            child: SwitchListTile(
              dense: true,
              title: const Text('Live transcribe'),
              value: _liveTranscribe,
              // Applied when the next recognition starts.
              onChanged: _recognitionActive
                  ? null
                  : (v) {
                      safeSetState(() {
                        _liveTranscribe = v;
                      });
                    },
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return DemoPageScaffold(
      model: widget.model,
      session: _session,
      scrollController: _scrollController,
      trailing: [
        TranscriptView(
          lines: _transcript,
          clearEnabled: !_recognitionActive,
          onClear: () {
            safeSetState(() {
              _transcript.clear();
            });
          },
        ),
      ],
      children: [
        _buildSourceSelector(),
        const SizedBox(height: 8),
        WaveformView(
          controller: _waveform,
          recording: _recognitionActive,
          recStart: _recStart,
          showWhenEmpty: _useMic,
        ),
        DemoRunButton(
          session: _session,
          stopMode: _recognitionActive,
          onPressed: () {
            if (_recognitionActive) {
              _stopRecognition();
              return;
            }
            _session.run(() => _useMic ? _runStreaming() : _runFile());
          },
        ),
      ],
    );
  }
}
