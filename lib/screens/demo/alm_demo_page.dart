import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';

import '../../backend_state.dart';
import '../../large_language_model/generation_metrics.dart';
import '../../large_language_model/multimodal_large_language_model.dart';
import '../../large_language_model/recorded_wav.dart';
import '../../model_catalog.dart';
import '../../utils/download_model.dart';
import 'chat_bubble.dart';
import 'demo_session.dart';
import 'waveform_view.dart';

/// Chats with Gemma 4 about local microphone recordings: the recording is
/// attached to the first message only, and follow-up questions continue
/// the same conversation. A new recording starts a new conversation.
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
  final ScrollController _scrollController = ScrollController();
  final List<ChatTurn> _turns = [];

  /// Backend the conversation runs on; a change reopens the model, which
  /// starts a new conversation.
  String? _conversationBackend;
  StreamSubscription<Amplitude>? _amplitude;

  /// Latest recording. It is attached to the first message of every
  /// conversation, so clearing the chat can ask about it again.
  File? _audio;
  double _audioSeconds = 0;
  DateTime? _recStart;
  bool _recording = false;
  bool _recordingBusy = false;

  @override
  void dispose() {
    _amplitude?.cancel();
    _alm.cancel();
    unawaited(_releaseRecorder());
    _query.dispose();
    _scrollController.dispose();
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
      final seconds = await prepareRecordedWav(File(path));
      if (!mounted) return;
      final restarted = _turns.isNotEmpty;
      // Each conversation is about one recording.
      if (restarted) _clearChat();
      safeSetState(() {
        _audio = File(path);
        _audioSeconds = seconds;
      });
      _session.showResult('Recorded ${seconds.toStringAsFixed(1)} seconds. '
          '${restarted ? 'Started a new conversation. ' : ''}'
          'Send a question to analyze it.');
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

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  void _clearChat() {
    _alm.clearHistory();
    _session.showResult('');
    safeSetState(_turns.clear);
  }

  bool get _canSend =>
      _audio != null && !_recording && !_recordingBusy && !_session.processing;

  Future<void> _send() async {
    final query = _query.text.trim();
    if (query.isEmpty || !_canSend) return;
    final backend = BackendState.instance.selectedLlmBackend.value;
    await _session.run(() async {
      if (!mounted) return;
      try {
        final files = _alm.getModelList(widget.model.id);
        if (!await _session.downloadModelList(files) || !mounted) return;
        final modelFile = File(await getModelPath(files[1]));
        final mmprojFile = File(await getModelPath(files[3]));
        if (!mounted) return;
        if (_conversationBackend != backend) {
          // The model is reopened, so the conversation starts over.
          _conversationBackend = backend;
          _alm.clearHistory();
          _turns.clear();
        }
        // Only the first message of a conversation carries the recording.
        final audio = _turns.isEmpty ? _audio : null;
        final user = ChatTurn.user(query);
        final reply = ChatTurn.assistant();
        _query.clear();
        safeSetState(() {
          _turns
            ..add(user)
            ..add(reply);
        });
        _scrollToBottom();
        final watch = Stopwatch()..start();
        int lastPaint = 0;
        double? ttftMs;
        double? tps;
        try {
          reply.text = await _alm.chatWithAudioIsolate(
              model: modelFile,
              mmproj: mmprojFile,
              backend: backend,
              nCtx: MultimodalLargeLanguageModel.contextSize(widget.model.id),
              systemPrompt: '',
              inputText: query,
              audioPath: audio?.path,
              onModelLoading: () =>
                  _session.setStatus('Loading audio model...'),
              onModelLoaded: () {
                _session.setStatus(
                    audio == null ? 'Generating...' : 'Audio Processing...');
              },
              onHistoryReset: () => safeSetState(() {
                    // Context full: the worker started a new conversation.
                    _turns.removeRange(0, _turns.indexOf(user));
                  }),
              onDelta: (delta) {
                if (reply.text.isEmpty) _session.clearStatus();
                reply.text += delta;
                if (watch.elapsedMilliseconds - lastPaint >= 33) {
                  lastPaint = watch.elapsedMilliseconds;
                  safeSetState(() {});
                  _scrollToBottom();
                }
              },
              onMetrics: (firstMs, tokensPerSecond) {
                ttftMs = firstMs;
                tps = tokensPerSecond;
              });
        } catch (_) {
          // A failed turn closes the model and its conversation; the next
          // message sends the recording again.
          _session.clearStatus();
          _conversationBackend = null;
          safeSetState(_turns.clear);
          rethrow;
        }
        _session.clearStatus();
        if (mounted) {
          safeSetState(() {});
          _scrollToBottom();
          _session
              .showResult('processing time : ${watch.elapsedMilliseconds} ms\n'
                  'TTFT: ${formatTtft(ttftMs)}\n'
                  'TPS: ${formatTps(tps)} tokens/s');
        }
      } finally {
        if (!mounted) {
          _alm.cancel();
          await _deleteRecordings();
        }
      }
    });
    if (!mounted) await _deleteRecordings();
  }

  @override
  Widget build(BuildContext context) => DemoPageScaffold(
        model: widget.model,
        session: _session,
        scrollController: _scrollController,
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
                      Row(children: [
                        FilledButton.icon(
                          onPressed: _recordingBusy || _session.processing
                              ? null
                              : () => _recording
                                  ? _stopRecording()
                                  : _startRecording(),
                          icon: Icon(_recording ? Icons.stop : Icons.mic),
                          label: Text(_recording
                              ? 'Stop recording'
                              : 'Start recording'),
                        ),
                        if (_audio != null && _turns.isEmpty) ...[
                          const SizedBox(width: 12),
                          Text('Audio ${_audioSeconds.toStringAsFixed(1)} s '
                              'will be sent with the next message'),
                        ],
                        const Spacer(),
                        IconButton(
                          tooltip: 'Clear conversation',
                          onPressed: _session.processing || _turns.isEmpty
                              ? null
                              : _clearChat,
                          icon: const Icon(Icons.delete_sweep, size: 20),
                        ),
                      ]),
                      for (final turn in _turns) ChatBubble(turn: turn),
                      const SizedBox(height: 8),
                      ChatInputRow(
                        controller: _query,
                        label: 'Audio query',
                        enabled: !_session.processing,
                        onSend: _canSend ? _send : null,
                      ),
                    ]),
                  )),
        ],
      );
}
