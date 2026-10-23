import 'dart:math';
import 'dart:typed_data';

import 'voice_agent_config.dart';

/// Motion equations from VoiceAgentOrbView.kt. Time is monotonic milliseconds;
/// callers supply a clock so frame timing and PCM decay can be verified.
class VoiceAgentOrbMotion {
  VoiceAgentOrbMotion({this.startedMs = 0});

  final double startedMs;
  final pointsX = Float32List(48);
  final pointsY = Float32List(48);
  final levels = Float32List(12);
  VoiceAgentState state = VoiceAgentState.preparing;
  double targetEnergy = 0;
  double energy = 0;
  double lastAudioMs = 0;
  double? _lastFrameMs;
  double motionPhase = 0;

  void setState(VoiceAgentState value) {
    state = value;
    targetEnergy = 0;
    levels.fillRange(0, levels.length, 0);
  }

  void setAudio(List<double> samples, double nowMs) {
    final rms = samples.isEmpty
        ? 0.0
        : sqrt(samples.fold(0.0, (sum, v) => sum + v * v) / samples.length);
    targetEnergy = min(sqrt(max(rms - .008, 0)) * 2.2, 1);
    for (var i = 0; i < levels.length; i++) {
      final start = i * samples.length ~/ levels.length;
      final end = (i + 1) * samples.length ~/ levels.length;
      var sum = 0.0;
      for (var j = start; j < end; j++) {
        sum += samples[j] * samples[j];
      }
      final value = end > start ? sqrt(sum / (end - start)) : 0.0;
      levels[i] = levels[i] * .4 + min(value * 6, 1) * .6;
    }
    lastAudioMs = nowMs;
  }

  bool get busy => switch (state) {
    VoiceAgentState.preparing ||
    VoiceAgentState.recognizing ||
    VoiceAgentState.thinking ||
    VoiceAgentState.synthesizing ||
    VoiceAgentState.synthesizingQuery ||
    VoiceAgentState.cancelling => true,
    _ => false,
  };

  void advance(double nowMs, double width, double height) {
    final dt = _lastFrameMs == null
        ? .016
        : ((nowMs - _lastFrameMs!) / 1000).clamp(.001, .05);
    _lastFrameMs = nowMs;
    if (nowMs - lastAudioMs > 180) {
      targetEnergy = 0;
      final decay = exp(-dt / .20);
      for (var i = 0; i < levels.length; i++) {
        levels[i] *= decay;
      }
    }
    final smoothing = 1 - exp(-dt / (targetEnergy > energy ? .045 : .20));
    energy += (targetEnergy - energy) * smoothing;
    final time = (nowMs - startedMs) / 1000;
    // Integrating speed avoids phase jumps as PCM changes or the state changes.
    motionPhase += dt * ((busy ? .7 : .35) + 5.5 * energy);
    final phase = motionPhase;
    final radius =
        min(width, height) *
        .30 *
        (1 +
            .32 * energy +
            .004 * sin(time * .7) +
            .016 * energy * sin(phase * 2.1));
    final cx = width / 2 + radius * (.005 + .010 * energy) * sin(phase * .9);
    final cy = height / 2 + radius * (.007 + .012 * energy) * sin(phase * 1.1);
    final stretchX =
        1 + .006 * sin(time * .6) + .065 * energy * sin(phase * 2.2);
    final stretchY =
        1 - .006 * sin(time * .6) + .060 * energy * cos(phase * 1.9);
    for (var i = 0; i < pointsX.length; i++) {
      final angle = i * pi * 2 / pointsX.length;
      final bandPosition = i * levels.length / pointsX.length;
      final bandIndex = bandPosition.toInt();
      final fraction = bandPosition - bandIndex;
      final band =
          levels[bandIndex] * (1 - fraction) +
          levels[(bandIndex + 1) % levels.length] * fraction;
      final wobble =
          .007 * sin(angle * 3 + phase) +
          .004 * cos(angle * 5 - phase * .85) +
          (busy ? .007 : .003) * sin(angle * 2 - phase * 1.2) +
          energy *
              (.075 * sin(angle * 3 + phase * 2.5) +
                  .025 * cos(angle * 5 - phase * 3.1) +
                  .020 * band);
      final r = radius * (1 + wobble);
      pointsX[i] = cx + cos(angle) * r * stretchX;
      pointsY[i] = cy + sin(angle) * r * stretchY;
    }
  }
}
