import 'package:flutter_test/flutter_test.dart';
import 'package:ailia_models_flutter/large_language_model/qnn_model.dart';

void main() {
  test('only HTP selects the QNN context binary path', () {
    expect(isLlmQnnBackend('HTP'), isTrue);
    expect(isLlmQnnBackend('HTP (QNN): Qualcomm Hexagon HTP'), isTrue);
    expect(isLlmQnnBackend('HTP: Qualcomm Hexagon HTP'), isTrue);
    for (final backend in ['CPU', 'Vulkan', 'OpenCL', 'Metal', 'QNN']) {
      expect(isLlmQnnBackend(backend), isFalse);
    }
  });
  test('selects a separate context binary for each supported Windows SoC', () {
    expect(qnnTextModelFiles('gemma4-e2b', 'sc8380xp'),
        ['gemma/qnn/v1.5.0', 'gemma4-e2b-sc8380xp.qnn']);
    expect(qnnTextModelFiles('gemma4-e2b', 'qcs6490'),
        ['gemma/qnn/v1.5.0', 'gemma4-e2b-qcs6490.qnn']);
  });

  test('rejects unsupported models and SoCs instead of substituting packages',
      () {
    expect(
        () => qnnTextModelFiles('gemma2', 'sc8380xp'), throwsUnsupportedError);
    expect(() => qnnTextModelFiles('gemma4-e2b', 'sm7635'),
        throwsUnsupportedError);
  });

  test('uses compiled context length for QNN and 8192 for GGUF', () {
    expect(llmContextLength('gemma4-e2b-sc8380xp.qnn', 'HTP'), 0);
    expect(llmContextLength('gemma4-e2b-qcs6490.qnn', 'HTP'), 0);
    expect(llmContextLength('gemma4.gguf', 'CPU'), 8192);
    expect(llmContextLength('gemma4.gguf', 'Vulkan'), 8192);
  });

  test('rejects mismatched model format before calling the native runtime', () {
    expect(() => llmContextLength('model.gguf', 'HTP'), throwsArgumentError);
    expect(() => llmContextLength('model.qnn', 'CPU'), throwsArgumentError);
  });
}
