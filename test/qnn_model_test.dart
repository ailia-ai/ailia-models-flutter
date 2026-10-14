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
        ['gemma/qnn/v1.5.1', 'gemma4-e2b-sc8380xp-fp16-mtp.qnn']);
    expect(qnnTextModelFiles('gemma4-e2b', 'qcs6490'),
        ['gemma/qnn/v1.5.1', 'gemma4-e2b-qcs6490-int16-mtp.qnn']);
  });

  test('rejects unsupported models and SoCs instead of substituting packages',
      () {
    expect(
        () => qnnTextModelFiles('gemma2', 'sc8380xp'), throwsUnsupportedError);
    expect(() => qnnTextModelFiles('gemma4-e2b', 'sm7635'),
        throwsUnsupportedError);
  });

  test('debug option loads the v1.5.0 context binaries', () {
    addTearDown(() => qnnModelFormat = QnnModelFormat.v151);
    expect(qnnModelFormat, QnnModelFormat.v151);
    qnnModelFormat = QnnModelFormat.v150;
    expect(qnnTextModelFiles('gemma4-e2b', 'sc8380xp'),
        ['gemma/qnn/v1.5.0', 'gemma4-e2b-sc8380xp.qnn']);
    expect(qnnTextModelFiles('gemma4-e4b', 'sc8380xp'),
        ['gemma/qnn/v1.5.0', 'gemma4-e4b-sc8380xp.qnn']);
    expect(qnnTextModelFiles('gemma4-e2b', 'qcs6490'),
        ['gemma/qnn/v1.5.0', 'gemma4-e2b-qcs6490.qnn']);
    // The assistant only exists for the v1.5.1 bodies.
    expect(mtpAssistantFiles('gemma4-e2b', 'HTP', soc: 'sc8380xp')[0],
        'gemma/qnn/v1.5.1');
  });

  test('MTP is unavailable only for the v1.5.0 QNN format', () {
    addTearDown(() => qnnModelFormat = QnnModelFormat.v151);
    expect(mtpAvailable('gemma4-e2b', 'HTP'), isTrue);
    expect(mtpAvailable('gemma2', 'CPU'), isFalse);
    qnnModelFormat = QnnModelFormat.v150;
    expect(mtpAvailable('gemma4-e2b', 'HTP'), isFalse);
    expect(mtpAvailable('gemma4-e2b-vlm', 'HTP (QNN): Qualcomm Hexagon HTP'),
        isFalse);
    // GGUF backends do not load .qnn files.
    expect(mtpAvailable('gemma4-e2b', 'CPU'), isTrue);
    expect(mtpAvailable('gemma4-e2b-alm', 'Metal'), isTrue);
  });

  test('selects the MTP assistant matching the body', () {
    expect(mtpAssistantFiles('gemma4-e2b', 'HTP', soc: 'sc8380xp'),
        ['gemma/qnn/v1.5.1', 'gemma4-e2b-sc8380xp-fp16-mtp-assistant.qnn']);
    expect(mtpAssistantFiles('gemma4-e2b-alm', 'HTP', soc: 'qcs6490'),
        ['gemma/qnn/v1.5.1', 'gemma4-e2b-qcs6490-int16-mtp-assistant.qnn']);
    expect(mtpAssistantFiles('gemma4-e4b', 'HTP', soc: 'sc8380xp'),
        ['gemma/qnn/v1.5.1', 'gemma4-e4b-sc8380xp-fp16-mtp-assistant.qnn']);
    expect(mtpAssistantFiles('gemma4-e2b-tool-use', 'CPU'),
        ['gemma', 'mtp-gemma-4-E2B-it-Q4_0.gguf']);
    expect(mtpAssistantFiles('gemma4-e4b', 'Vulkan'),
        ['gemma', 'mtp-gemma-4-E4B-it-Q4_0.gguf']);
    expect(() => mtpAssistantFiles('gemma2', 'CPU'), throwsUnsupportedError);
    expect(() => mtpAssistantFiles('gemma4-e4b', 'HTP', soc: 'qcs6490'),
        throwsUnsupportedError);
    expect(supportsMtp('gemma3-multimodal'), isFalse);
    expect(mtpDraftTokens, 3);
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
