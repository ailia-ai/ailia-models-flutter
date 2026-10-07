/// Times generated tokens without including model loading or tool execution.
class GenerationMetrics {
  final Stopwatch _watch = Stopwatch();
  int _tokenCount = 0;
  int? _firstTokenUs;
  int? _lastTokenUs;

  void start() {
    _watch
      ..reset()
      ..start();
  }

  void recordToken() => recordTokenAt(_watch.elapsed);

  /// Accepts an explicit timestamp so the rate calculation can be tested.
  void recordTokenAt(Duration elapsed) {
    final us = elapsed.inMicroseconds;
    _firstTokenUs ??= us;
    _lastTokenUs = us;
    _tokenCount++;
  }

  double? get ttftMs => _firstTokenUs == null ? null : _firstTokenUs! / 1000;

  /// The first token belongs to TTFT; subsequent tokens measure decode speed.
  int get decodeTokens => _tokenCount > 0 ? _tokenCount - 1 : 0;

  double get decodeSeconds => _firstTokenUs == null || _lastTokenUs == null
      ? 0
      : (_lastTokenUs! - _firstTokenUs!) / 1000000;

  double? get tps => decodeTokens == 0 || decodeSeconds <= 0
      ? null
      : decodeTokens / decodeSeconds;
}

String formatTps(double? tps) => tps == null ? 'N/A' : tps.toStringAsFixed(1);

String formatTtft(double? ttftMs) =>
    ttftMs == null ? 'N/A' : '${ttftMs.toStringAsFixed(0)} ms';
