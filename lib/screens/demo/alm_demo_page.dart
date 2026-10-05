import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:wav/wav.dart';

import '../../backend_state.dart';
import '../../large_language_model/multimodal_large_language_model.dart';
import '../../model_catalog.dart';
import '../../utils/download_model.dart';
import 'demo_session.dart';
import 'waveform_view.dart';

/// Records a local WAV and sends audio plus a text query to Gemma 4.
class AlmDemoPage extends StatefulWidget {
  const AlmDemoPage({super.key, required this.model});
  final ModelInfo model;

  @override
  State<AlmDemoPage> createState() => _AlmDemoPageState();
}

class _AlmDemoPageState extends State<AlmDemoPage> with SafeSetStateMixin {
  final DemoSession _session = DemoSession();
  final MultimodalLargeLanguageModel _alm = MultimodalLargeLanguageModel();
  final AudioRecorder _recorder = AudioRecorder();
  final WaveformController _waveform = WaveformController();
  final TextEditingController _query =
      TextEditingController(text: 'この音声を日本語で文字起こししてください。');
  final List<File> _recordings = [];
  StreamSubscription<Amplitude>? _amplitude;
  File? _audio;
  DateTime? _recStart;
  bool _recording = false;
  bool _recordingBusy = false;

  @override
  void dispose() {
    _amplitude?.cancel();
    _alm.cancel();
    unawaited(_releaseRecorder());
    _query.dispose();
    _waveform.dispose();
    _session.dispose();
    super.dispose();
  }

  Future<void> _releaseRecorder() async {
    try {
      await _recorder.cancel();
    } catch (_) {}
    try {
      await _recorder.dispose();
    } catch (_) {}
    // Native inference may still be reading the audio during prompt setup;
    // _runAudio deletes its recording after the model closes if unmounted.
    if (!_session.processing) await _deleteRecordings();
  }

  Future<void> _deleteRecordings() async {
    for (final file in _recordings) {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  Future<void> _startRecording() async {
    if (_recordingBusy || _recording || _session.processing) return;
    safeSetState(() => _recordingBusy = true);
    _session.errorText = null;
    try {
      if (!await _recorder.hasPermission()) {
        throw StateError('Microphone permission denied.');
      }
      if (!mounted) return;
      final temp = await getTemporaryDirectory();
      if (!mounted) return;
      final file = File(
          '${temp.path}/ailia-alm-${DateTime.now().microsecondsSinceEpoch}.wav');
      _recordings.add(file);
      await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: file.path);
      if (!mounted) return;
      _waveform.clear();
      _amplitude = _recorder
          .onAmplitudeChanged(const Duration(milliseconds: 100))
          .listen((amplitude) {
        if (!mounted) return;
        final peak = math
            .pow(10, amplitude.current / 20)
            .toDouble()
            .clamp(0.0, 1.0)
            .toDouble();
        _waveform.push(List.filled(10, peak));
      }, onError: (Object error) {
        _session.showError('Microphone error: $error');
        if (_recording) unawaited(_stopRecording());
      });
      safeSetState(() {
        _audio = null;
        _recording = true;
        _recStart = DateTime.now();
      });
      _session.showResult('Recording from microphone. Stop when finished.');
    } catch (e) {
      try {
        await _recorder.cancel();
      } catch (_) {}
      _session.showError('Recording failed: $e');
    } finally {
      safeSetState(() => _recordingBusy = false);
    }
  }

  Future<void> _stopRecording() async {
    if (!_recording || _recordingBusy) return;
    safeSetState(() => _recordingBusy = true);
    try {
      final path = await _recorder.stop();
      await _amplitude?.cancel();
      _amplitude = null;
      if (path == null) throw StateError('No microphone recording was saved.');
      final wav = await Wav.readFile(path);
      if (wav.channels.isEmpty || wav.channels.first.isEmpty) {
        throw StateError('The microphone recording is empty.');
      }
      if (!mounted) return;
      safeSetState(() => _audio = File(path));
      final seconds = wav.channels.first.length / wav.samplesPerSecond;
      _session.showResult(
          'Recorded ${seconds.toStringAsFixed(1)} seconds. Press Analyze audio.');
    } catch (e) {
      try {
        await _recorder.cancel();
      } catch (_) {}
      _session.showError('Recording failed: $e');
    } finally {
      await _amplitude?.cancel();
      _amplitude = null;
      safeSetState(() {
        _recording = false;
        _recordingBusy = false;
      });
    }
  }

  Future<void> _runAudio() async {
    final audio = _audio;
    final query = _query.text.trim();
    if (audio == null ||
        query.isEmpty ||
        _recording ||
        _recordingBusy ||
        _session.processing) {
      return;
    }
    final backend = BackendState.instance.selectedLlmBackend.value;
    await _session.run(() async {
      if (!mounted) return;
      try {
        final files = _alm.getModelList(widget.model.id, backend);
        if (!await _session.downloadModelList(files) || !mounted) return;
        _session.setStatus('Loading audio model...');
        final modelFile = File(await getModelPath(files[1]));
        final mmprojFile = File(await getModelPath(files[3]));
        if (!mounted) return;
        _session.clearStatus();
        _session.showResult('');
        final watch = Stopwatch()..start();
        final reply = StringBuffer();
        int lastPaint = 0;
        await _alm.chatWithAudioIsolate(
            model: modelFile,
            mmproj: mmprojFile,
            backend: backend,
            nCtx: MultimodalLargeLanguageModel.contextSize(
                widget.model.id, modelFile.path, backend),
            systemPrompt: 'あなたは音声を理解する親切なアシスタントです。',
            inputText: query,
            audioPath: audio.path,
            onDelta: (delta) {
              reply.write(delta);
              if (watch.elapsedMilliseconds - lastPaint >= 33) {
                lastPaint = watch.elapsedMilliseconds;
                _session.showResult(reply.toString());
              }
            });
        if (mounted) {
          _session.showResult(
              '$reply\nprocessing time : ${watch.elapsedMilliseconds} ms');
        }
      } finally {
        _alm.cancel();
        if (!mounted) await _deleteRecordings();
      }
    });
    if (!mounted) await _deleteRecordings();
  }

  @override
  Widget build(BuildContext context) => DemoPageScaffold(
        model: widget.model,
        session: _session,
        children: [
          const Text('Microphone audio is processed locally by Gemma 4 E2B.'),
          WaveformView(
              controller: _waveform,
              recording: _recording,
              recStart: _recStart,
              showWhenEmpty: true),
          ListenableBuilder(
              listenable: _session,
              builder: (context, _) => DemoPanel(
                    child: Column(children: [
                      TextField(
                          controller: _query,
                          minLines: 2,
                          maxLines: 4,
                          enabled: !_session.processing,
                          decoration: const InputDecoration(
                              labelText: 'Audio query',
                              border: OutlineInputBorder())),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _recordingBusy || _session.processing
                            ? null
                            : () => _recording
                                ? _stopRecording()
                                : _startRecording(),
                        icon: Icon(_recording ? Icons.stop : Icons.mic),
                        label: Text(
                            _recording ? 'Stop recording' : 'Start recording'),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed: _audio == null ||
                                _recording ||
                                _recordingBusy ||
                                _session.processing
                            ? null
                            : _runAudio,
                        icon: const Icon(Icons.auto_awesome),
                        label: Text(_session.processing
                            ? 'Processing...'
                            : 'Analyze audio'),
                      ),
                    ]),
                  )),
        ],
      );
}
