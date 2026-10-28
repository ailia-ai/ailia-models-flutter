import 'dart:math';

/// Exclude only the known playback settling interval. Quiet speech is preserved.
class VoiceAgentInputGate {
  VoiceAgentInputGate(this.remaining);
  int remaining;
  List<double> accept(List<double> audio) {
    final count = min(remaining, audio.length);
    remaining -= count;
    return audio.sublist(count);
  }
}

abstract interface class VoiceAgentSpeechEngine {
  void push(List<double> audio, int sampleRate, int channels);
  bool get buffered;
  void finalize();
  List<String> transcribe();
  bool get complete;
  void reset();
}

/// Non-LIVE Silero protocol: first Buffered → finalize → drain → Complete → reset.
class VoiceAgentSpeechTurn {
  VoiceAgentSpeechTurn(this.engine);
  final VoiceAgentSpeechEngine engine;
  bool _finalized = false;

  bool push(List<double> audio, int sampleRate, {int channels = 1}) {
    if (_finalized) throw StateError('確定済みの音声入力に追加できません');
    engine.push(audio, sampleRate, channels);
    return engine.buffered;
  }

  List<String> finish(void Function() checkActive) {
    if (_finalized) throw StateError('音声入力はすでに確定しています');
    checkActive();
    _finalized = true;
    engine.finalize();
    final lines = <String>[];
    while (engine.buffered) {
      checkActive();
      lines.addAll(engine.transcribe());
    }
    if (!engine.complete) throw StateError('音声認識が完了状態になりませんでした');
    engine.reset();
    _finalized = false;
    return lines;
  }
}
