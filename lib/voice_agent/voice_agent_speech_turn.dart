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

/// Non-LIVE Silero protocol: first VadBuffered → finalize → drain → Complete → reset.
class VoiceAgentSpeechTurn {
  VoiceAgentSpeechTurn(this.engine);
  final VoiceAgentSpeechEngine engine;
  bool _finalized = false;

  bool push(List<double> audio, int sampleRate, {int channels = 1}) {
    if (_finalized) throw StateError('確定済みの音声入力に追加できません');
    engine.push(audio, sampleRate, channels);
    return engine.buffered;
  }

  /// [onText] receives the text recognized so far after each transcribe,
  /// before the remaining drain and reset, so the display can replace the
  /// empty intermediate text without waiting for the turn to close.
  List<String> finish(
    void Function() checkActive, {
    void Function(List<String> lines)? onText,
  }) {
    if (_finalized) throw StateError('音声入力はすでに確定しています');
    checkActive();
    _finalized = true;
    engine.finalize();
    final lines = <String>[];
    while (engine.buffered) {
      checkActive();
      lines.addAll(engine.transcribe());
      onText?.call(List.unmodifiable(lines));
    }
    if (!engine.complete) throw StateError('音声認識が完了状態になりませんでした');
    engine.reset();
    _finalized = false;
    return lines;
  }
}
