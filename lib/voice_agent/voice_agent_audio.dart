import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:wav/wav.dart';

import 'voice_agent_config.dart';
import 'voice_agent_text.dart';
import 'voice_agent_worker.dart';

class VoiceAgentAudio {
  VoiceAgentAudio(this.pcm, this.sampleRate, this.channels);
  factory VoiceAgentAudio.fromMap(Map value) => VoiceAgentAudio(
    Float64List.fromList((value['pcm'] as List).cast<double>()),
    value['rate'] as int,
    value['channels'] as int,
  );
  final Float64List pcm;
  final int sampleRate;
  final int channels;
}

class VoiceAgentPlayer {
  VoiceAgentPlayer() {
    _player.positionUpdater = TimerPositionUpdater(
      interval: const Duration(milliseconds: 40),
      getPosition: _player.getCurrentPosition,
    );
  }
  final _player = AudioPlayer();
  Completer<void>? _playback;
  DateTime? _stoppedAt;
  VoiceAgentAudio? lastTail;
  int _generation = 0;

  int get remainingSettleMs => max(
    0,
    400 -
        (_stoppedAt == null
            ? 400
            : DateTime.now().difference(_stoppedAt!).inMilliseconds),
  );

  Future<void> play(
    VoiceAgentAudio audio,
    Directory cache,
    void Function(List<double>) waveform,
  ) async {
    final generation = _generation;
    final count = audio.pcm.length ~/ audio.channels;
    final channels = List.generate(
      audio.channels,
      (channel) => Float64List.fromList([
        for (var i = 0; i < count; i++) audio.pcm[i * audio.channels + channel],
      ]),
    );
    final file = File('${cache.path}/playback.wav');
    await Wav(
      channels,
      audio.sampleRate,
      WavFormat.pcm16bit,
    ).writeFile(file.path);
    if (generation != _generation) throw const VoiceAgentCancelled();
    final done = Completer<void>();
    _playback = done;
    final completion = _player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    final position = _player.onPositionChanged.listen((time) {
      final start =
          (time.inMicroseconds * audio.sampleRate ~/ 1000000) * audio.channels;
      if (start < audio.pcm.length) {
        waveform(
          audio.pcm.sublist(
            start,
            min(
              audio.pcm.length,
              start + audio.sampleRate ~/ 20 * audio.channels,
            ),
          ),
        );
      }
    });
    try {
      await _player.play(DeviceFileSource(file.path));
      if (generation != _generation) {
        await _player.stop();
        throw const VoiceAgentCancelled();
      }
      await done.future;
      final tailLength = min(
        audio.pcm.length,
        audio.sampleRate * audio.channels * 400 ~/ 1000,
      );
      lastTail = VoiceAgentAudio(
        Float64List.fromList(audio.pcm.sublist(audio.pcm.length - tailLength)),
        audio.sampleRate,
        audio.channels,
      );
    } finally {
      _stoppedAt = DateTime.now();
      _playback = null;
      await completion.cancel();
      await position.cancel();
      waveform(const []);
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> stop() async {
    ++_generation;
    await _player.stop();
    _stoppedAt = DateTime.now();
    if (_playback != null && !_playback!.isCompleted) _playback!.complete();
  }

  Future<void> dispose() async {
    await stop();
    await _player.dispose();
  }
}

/// LLM events only enqueue text. Synthesis and playback run independently, with
/// at most two finished PCM clips waiting. Playback starts after generation.
class VoiceAgentSpeechQueue {
  VoiceAgentSpeechQueue({
    required this.worker,
    required this.open,
    required this.play,
    required this.stopPlayback,
  }) {
    // Both tasks catch their own errors immediately, even while Gemma is busy.
    _producer = _produce();
    _consumer = _consume();
  }
  final VoiceAgentWorker worker;
  final Future<void> Function() open;
  final Future<void> Function(VoiceAgentAudio) play;
  final Future<void> Function() stopPlayback;
  final _text = VoiceAgentSpeechText();
  final _phrases = StreamController<String>();
  final _clips = StreamController<VoiceAgentAudio>();
  final _playbackReady = Completer<void>();
  final _waiting = <Completer<void>>[];
  late final Future<void> _producer;
  late final Future<void> _consumer;
  Object? _error;
  bool _stopped = false;
  bool _finished = false;
  int _queuedClips = 0;

  void update(String text, {required bool complete}) {
    if (_stopped || _finished) return;
    for (final phrase in _text.update(text, complete: complete)) {
      _phrases.add(phrase);
    }
  }

  void _wake() {
    for (final waiter in _waiting) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiting.clear();
  }

  void _failed(Object error) {
    _error ??= error;
    _stopped = true;
    if (!_playbackReady.isCompleted) _playbackReady.complete();
    _wake();
    unawaited(_phrases.close());
  }

  Future<void> _produce() async {
    var listening = false;
    try {
      await open();
      listening = true;
      await for (final phrase in _phrases.stream) {
        if (_stopped) break;
        while (_queuedClips >= 2 && !_stopped) {
          final space = Completer<void>();
          _waiting.add(space);
          await space.future;
        }
        if (_stopped) break;
        final audio = await worker.call('synthesize', {'text': phrase});
        if (_stopped) break;
        _queuedClips++;
        _clips.add(VoiceAgentAudio.fromMap(audio as Map));
      }
    } catch (error) {
      _failed(error);
    } finally {
      // A failed open must still have a listener to let close() complete.
      if (!listening) {
        unawaited(_phrases.stream.drain<void>());
      }
      await _clips.close();
    }
  }

  Future<void> _consume() async {
    try {
      await for (final clip in _clips.stream) {
        await _playbackReady.future;
        _queuedClips--;
        _wake();
        if (!_stopped) await play(clip);
      }
    } catch (error) {
      _failed(error);
    }
  }

  Future<void> finish() async {
    _finished = true;
    unawaited(_phrases.close());
    if (!_playbackReady.isCompleted) _playbackReady.complete();
    await Future.wait([_producer, _consumer]);
    if (_error != null) throw _error!;
    if (_stopped) throw const VoiceAgentCancelled();
  }

  Future<void> close() async {
    _stopped = true;
    worker.cancel();
    unawaited(_phrases.close());
    if (!_playbackReady.isCompleted) _playbackReady.complete();
    _wake();
    await stopPlayback();
    await Future.wait([_producer, _consumer]);
    await worker.call('voiceRelease');
  }
}
