import 'package:ailia_models_flutter/large_language_model/generation_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('TTFT and TPS use first token and subsequent decode intervals', () {
    final timing = GenerationMetrics();
    timing.recordTokenAt(const Duration(milliseconds: 250));
    timing.recordTokenAt(const Duration(milliseconds: 350));
    timing.recordTokenAt(const Duration(milliseconds: 450));

    expect(timing.ttftMs, 250);
    expect(timing.decodeTokens, 2);
    expect(timing.decodeSeconds, closeTo(0.2, 0.000001));
    expect(timing.tps, closeTo(10, 0.000001));
    expect(formatTtft(timing.ttftMs), '250 ms');
    expect(formatTps(timing.tps), '10.0');
  });

  test('unavailable rates have an explicit display value', () {
    final timing = GenerationMetrics();
    expect(timing.ttftMs, isNull);
    expect(formatTps(timing.tps), 'N/A');
    timing.recordTokenAt(const Duration(milliseconds: 50));
    expect(timing.tps, isNull);
  });
}
