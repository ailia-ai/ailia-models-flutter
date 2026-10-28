import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:ailia/ailia_license.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:wav/wav.dart';

import '../audio_processing/whisper.dart';
import '../large_language_model/qnn_runtime.dart';
import '../text_to_speech/text_to_speech.dart';
import '../utils/download_model.dart';
import '../utils/qnn_env.dart';
import 'voice_agent_audio.dart';
import 'voice_agent_camera.dart';
import 'voice_agent_config.dart';
import 'voice_agent_download.dart';
import 'voice_agent_speech_turn.dart';
import 'voice_agent_worker.dart';

class VoiceAgentController extends ChangeNotifier {
  VoiceAgentState state = VoiceAgentState.preparing;
  int stateRevision = 0;
  bool active = false;
  String input = '';
  String output = '';
  String progress = '';
  double? downloadProgress;
  String? error;
  double? temperature;
  Uint8List? photo;
  final waveform = ValueNotifier<List<double>>(const []);
  bool canSend = false;
  VoiceAgentDownloader? _downloader;

  VoiceAgentWorker? _models;
  VoiceAgentWorker? _voice;
  VoiceAgentPlayer? _player;
  AudioRecorder? _recorder;
  Future<Stream<Uint8List>>? _micOpening;
  Future<void>? _micStopping;
  StreamSubscription<Uint8List>? _micSubscription;
  StreamController<Float64List>? _mic;
  Timer? _recordingLimit;
  Directory? _cache;
  VoiceAgentSpeechQueue? _speechQueue;
  Future<void>? _task;
  Completer<void>? _resume;
  bool _disposed = false;
  bool _stopping = false;
  bool _testMode = false;
  int _turn = 0;
  late VoiceAgentConfig _config;
  late List<String> _speechFiles;
  late List<String> _llmFiles;
  late Map<String, dynamic> _voiceArgs;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _state(VoiceAgentState value) {
    state = value;
    stateRevision++;
    _notify();
  }

  void _check([int? turn]) {
    if (_stopping || _disposed || (turn != null && turn != _turn)) {
      throw const VoiceAgentCancelled();
    }
  }

  void _waveform(List<double> pcm) {
    if (_disposed) return;
    waveform.value = pcm;
  }

  Future<void> start(VoiceAgentConfig config) {
    if (active) return _task ?? Future.value();
    active = true;
    _stopping = false;
    _testMode = config.testMode;
    _config = config;
    _downloader = VoiceAgentDownloader();
    error = null;
    input = output = progress = '';
    temperature = null;
    photo = null;
    waveform.value = const [];
    _state(VoiceAgentState.preparing);
    return _task = _run();
  }

  Future<List<String>> _download(List<String> pairs) async {
    final files = <String>[];
    for (var i = 0; i < pairs.length; i += 2) {
      _check();
      final name = pairs[i + 1];
      progress = 'Downloading $name';
      _notify();
      final file = File(await getModelPath(name));
      await _downloader!.download(
        Uri.parse(
          'https://storage.googleapis.com/ailia-models/${pairs[i]}/${path.basename(name)}',
        ),
        file,
        (int bytes, int total) {
          if (_stopping) return;
          progress = '$name (${bytes ~/ 1048576} / ${total ~/ 1048576} MB)';
          downloadProgress = total > 0 ? bytes / total : null;
          _notify();
        },
      );
      _check();
      files.add(file.path);
    }
    return files;
  }

  Future<void> _prepare() async {
    _config.validate();
    await AiliaLicense.checkAndDownloadLicense();
    _check();
    _cache = await (await getTemporaryDirectory()).createTemp(
      'ailia-voice-agent-',
    );
    final speech = await _download(
      AudioProcessingWhisper().getModelList(
        _config.speechModel,
        _config.speechEnvId,
      ),
    );
    _speechFiles = speech.take(3).toList();
    _llmFiles = await _download(
      _config.llmFiles(soc: availableWindowsQnnSoc()),
    );
    if (_config.needsVoice) {
      await _download(
        TextToSpeech().getModelList(
          TextToSpeech.MODEL_TYPE_GPT_SOVITS_V2_PRO_DISTILL_BASE_JA,
        ),
      );
      final reference = Wav.read(
        (await rootBundle.load(
          'assets/reference_audio_girl.wav',
        )).buffer.asUint8List(),
      );
      _voiceArgs = {
        'root': await getModelPath(''),
        'env': _config.voiceEnvId,
        'rate': reference.samplesPerSecond,
        'channels': reference.channels.length,
        'reference': Float64List.fromList([
          for (var i = 0; i < reference.channels.first.length; i++)
            for (final channel in reference.channels) channel[i],
        ]),
      };
    }
    _check();
    progress = '';
    downloadProgress = null;
    _models = VoiceAgentWorker();
    await _models!.start();
    _check();
    if (_config.needsVoice) {
      _voice = VoiceAgentWorker();
      await _voice!.start();
      _check();
    }
    _player = VoiceAgentPlayer();
  }

  Future<void> _run() async {
    try {
      await _prepare();
      var queryIndex = 0;
      while (!_stopping) {
        final turn = ++_turn;
        try {
          if (_testMode && queryIndex >= _config.queries.length) {
            _state(VoiceAgentState.testComplete);
            _resume = Completer<void>();
            await _resume!.future;
            _resume = null;
            _check(turn);
          }
          final utterance = _testMode
              ? await _query(_config.queries[queryIndex++], turn)
              : await _listen(turn);
          _check(turn);
          input = utterance;
          _notify();
          if (_testMode && utterance.trim().isEmpty) {
            throw StateError('テスト音声を認識できませんでした');
          }
          if (utterance.trim().isNotEmpty) await _respond(utterance, turn);
        } on VoiceAgentCancelled {
          // Interruption changes to microphone mode after both workers drain.
        } finally {
          _models?.onEvent = null;
          final queue = _speechQueue;
          _speechQueue = null;
          if (queue != null) await queue.close();
          canSend = false;
          await _stopMic();
        }
      }
    } on VoiceAgentCancelled {
      // Session end, including while preparing or opening a native model.
    } catch (failure) {
      error = '$failure';
    } finally {
      _stopping = true;
      await _cleanup();
      active = false;
      progress = '';
      downloadProgress = null;
      temperature = null;
      photo = null;
      if (!_disposed) waveform.value = const [];
      _notify();
    }
  }

  void _modelEvents(int turn) {
    _models!.onEvent = (event) {
      if (_stopping || turn != _turn) return;
      switch (event['type']) {
        case 'input':
          input = event['text'] as String;
        case 'output':
          output = event['text'] as String;
          _speechQueue?.update(output, complete: event['complete'] == true);
        case 'temperature':
          temperature = (event['value'] as num).toDouble();
      }
      _notify();
    };
    _models!.takePhoto = () async {
      _check(turn);
      final bytes = await VoiceAgentCamera().capture(
        front: _config.frontCamera,
        deviceId: _config.cameraDeviceId,
        checkActive: () => _check(turn),
      );
      _check(turn);
      photo = bytes;
      _notify();
      return voiceAgentPhotoData(bytes);
    };
  }

  Future<void> _openSpeech(int turn) async {
    _modelEvents(turn);
    await _models!.call('listen', {
      'files': _speechFiles,
      'env': speechEngineEnvId(_config.speechEnvId),
      'model': _config.speechModel,
    });
    _check(turn);
  }

  Future<String> _recognize(int turn) async {
    _state(VoiceAgentState.submitting);
    _check(turn);
    _state(VoiceAgentState.recognizing);
    final text = await _models!.call('recognize') as String;
    _check(turn);
    return text;
  }

  Future<String> _listen(int turn) async {
    _check(turn);
    final recorder = AudioRecorder();
    _recorder = recorder;
    if (!await recorder.hasPermission()) {
      throw StateError('マイクへのアクセスが許可されていません');
    }
    _check(turn);
    final mic = StreamController<Float64List>();
    _mic = mic;
    _state(VoiceAgentState.listening);
    var skip = _player!.remainingSettleMs * 16;
    var recorded = 0;
    int? pendingByte;
    final opening = recorder.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ),
    );
    _micOpening = opening;
    final stream = await opening;
    _micOpening = null;
    _check(turn);
    _micSubscription = stream.listen(
      (bytes) {
        if (turn != _turn || _stopping || mic.isClosed) return;
        // Stream boundaries need not align with 16-bit PCM samples.
        final all = pendingByte == null
            ? bytes
            : Uint8List.fromList([pendingByte!, ...bytes]);
        pendingByte = all.length.isOdd ? all.last : null;
        final data = ByteData.sublistView(all);
        final pcm = Float64List(all.length ~/ 2);
        for (var i = 0; i < pcm.length; i++) {
          pcm[i] = data.getInt16(i * 2, Endian.little) / 32768;
        }
        final drop = min(skip, pcm.length);
        skip -= drop;
        final accepted = pcm.sublist(drop);
        if (accepted.isEmpty) return;
        recorded += accepted.length;
        final enableSend = !canSend;
        canSend = true;
        _waveform(accepted);
        if (enableSend) _notify();
        mic.add(accepted);
        if (recorded >= 16000 * 30) unawaited(send());
      },
      onError: (Object error) {
        if (!mic.isClosed) mic.addError(error);
      },
      onDone: () {
        if (!mic.isClosed) unawaited(mic.close());
      },
    );
    // Capture queues while Whisper initializes, bounded by the 30-second limit.
    _recordingLimit = Timer(
      const Duration(seconds: 30),
      () => unawaited(send()),
    );
    var consuming = false;
    try {
      await _openSpeech(turn);
      consuming = true;
      await for (final pcm in mic.stream) {
        _check(turn);
        if (await _models!.call('push', {'pcm': pcm, 'rate': 16000}) == true) {
          break;
        }
      }
      _check(turn);
      await _stopMic();
      return await _recognize(turn);
    } finally {
      // Opening can fail before the stream receives a listener.
      if (!consuming) unawaited(mic.stream.drain<void>());
      await _stopMic();
    }
  }

  Future<void> send() async {
    if (state != VoiceAgentState.listening || !canSend) return;
    canSend = false;
    _state(VoiceAgentState.submitting);
    await _stopMic();
  }

  Future<void> _stopMic() => _micStopping ??= _closeMic().whenComplete(() {
    _micStopping = null;
  });

  Future<void> _closeMic() async {
    _recordingLimit?.cancel();
    _recordingLimit = null;
    final mic = _mic;
    _mic = null;
    if (mic != null && !mic.isClosed) unawaited(mic.close());
    final subscription = _micSubscription;
    _micSubscription = null;
    await subscription?.cancel();
    final recorder = _recorder;
    _recorder = null;
    if (recorder != null) {
      final opening = _micOpening;
      _micOpening = null;
      try {
        await opening;
      } catch (_) {
        /* Still dispose a failed capture. */
      }
      try {
        await recorder.stop();
      } finally {
        await recorder.dispose();
      }
    }
    canSend = false;
  }

  Future<void> _play(
    VoiceAgentAudio audio,
    int turn,
    VoiceAgentState playing,
  ) async {
    _check(turn);
    _state(playing);
    await _player!.play(audio, _cache!, (pcm) {
      if (turn == _turn && !_stopping) _waveform(pcm);
    });
    _check(turn);
  }

  Future<String> _query(String query, int turn) async {
    _state(VoiceAgentState.synthesizingQuery);
    late VoiceAgentAudio audio;
    try {
      await _voice!.call('voiceOpen', _voiceArgs);
      _check(turn);
      audio = VoiceAgentAudio.fromMap(
        await _voice!.call('synthesize', {'text': query}) as Map,
      );
    } finally {
      await _voice!.call('voiceRelease');
    }
    _check(turn);
    _state(VoiceAgentState.waitingQuery);
    await _openSpeech(turn);
    final previous = _player!.lastTail;
    final valuesPerSecond = audio.sampleRate * audio.channels;
    final gate = VoiceAgentInputGate(valuesPerSecond * 400 ~/ 1000);
    Future<bool> feed(List<double> pcm) async {
      _check(turn);
      final accepted = gate.accept(pcm);
      return accepted.isNotEmpty &&
          await _models!.call('push', {
                'pcm': accepted,
                'rate': audio.sampleRate,
                'channels': audio.channels,
              }) ==
              true;
    }

    // The same gate as microphone capture excludes 400 ms of playback tail.
    final tail = Float64List(gate.remaining);
    if (previous?.sampleRate == audio.sampleRate &&
        previous?.channels == audio.channels) {
      tail.setRange(0, min(tail.length, previous!.pcm.length), previous.pcm);
    }
    if (await feed(tail)) throw StateError('再生音の末尾が新しい発話として検出されました');
    if (await feed(Float64List(valuesPerSecond * 12 ~/ 10))) {
      throw StateError('無音が発話として検出されました');
    }
    // Query text never reaches Gemma: feed the synthesized PCM through Silero.
    await _play(audio, turn, VoiceAgentState.playingQuery);
    var buffered = false;
    for (
      var i = 0;
      i < audio.pcm.length && !buffered;
      i += valuesPerSecond ~/ 10
    ) {
      _check(turn);
      buffered = await feed(
        audio.pcm.sublist(i, min(audio.pcm.length, i + valuesPerSecond ~/ 10)),
      );
    }
    for (var i = 0; i < 20 && !buffered; i++) {
      _check(turn);
      buffered = await feed(Float64List(valuesPerSecond ~/ 10));
    }
    if (!buffered) throw StateError('テスト音声が発話として検出されませんでした');
    return _recognize(turn);
  }

  Future<void> _respond(String utterance, int turn) async {
    output = '';
    _state(VoiceAgentState.thinking);
    _modelEvents(turn);
    if (_config.speechOutput) {
      _speechQueue = VoiceAgentSpeechQueue(
        worker: _voice!,
        open: () async {
          await _voice!.call('voiceOpen', _voiceArgs);
          _check(turn);
        },
        play: (audio) => _play(audio, turn, VoiceAgentState.speaking),
        stopPlayback: _player!.stop,
      );
    }
    final answer =
        await _models!.call('reply', {
              'input': utterance,
              'body': _llmFiles[0],
              'projector': _llmFiles[1],
              'mtp': _llmFiles.length > 2 ? _llmFiles[2] : null,
              'backend': _config.llmBackend,
            })
            as String;
    _check(turn);
    output = answer;
    _notify();
    if (_speechQueue != null) {
      _state(VoiceAgentState.synthesizing);
      await _speechQueue!.finish();
      _check(turn);
    }
  }

  Future<void> interrupt() async {
    if (!active || _stopping || !state.interruptible) return;
    ++_turn;
    _testMode = false;
    _state(VoiceAgentState.cancelling);
    _models?.cancel();
    _voice?.cancel();
    _resume?.complete();
    _resume = null;
    await _stopMic();
    await _player?.stop();
  }

  Future<void> stop() async {
    if (!active) return;
    _stopping = true;
    _downloader?.cancel();
    ++_turn;
    _state(VoiceAgentState.stopping);
    _models?.cancel();
    _voice?.cancel();
    _resume?.complete();
    _resume = null;
    await _stopMic();
    await _player?.stop();
    await _task;
  }

  Future<void> _cleanup() async {
    Future<void> release(Future<void> Function() action) async {
      try {
        await action();
      } catch (failure) {
        error ??= '$failure';
      }
    }

    await release(_stopMic);
    final queue = _speechQueue;
    _speechQueue = null;
    if (queue != null) await release(queue.close);
    final player = _player;
    if (player != null) await release(player.dispose);
    _player = null;
    final models = _models;
    final voice = _voice;
    if (models != null) await release(models.close);
    if (voice != null) await release(voice.close);
    _models = _voice = null;
    final cache = _cache;
    _cache = null;
    if (cache != null) {
      await release(() async {
        if (await cache.exists()) await cache.delete(recursive: true);
      });
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(stop());
    waveform.dispose();
    super.dispose();
  }
}
