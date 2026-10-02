import 'package:flutter_test/flutter_test.dart';
import 'package:ailia_models_flutter/model_catalog.dart';
import 'package:ailia_models_flutter/utils/qnn_support.dart';
import 'package:ailia_models_flutter/large_language_model/qnn_model.dart';

void main() {
  test('FP16 depends on the SoC rather than just the Hexagon version', () {
    for (final soc in ['qcs6490', 'sm7635', 'sm8635', 'sm8735', 'sm7475']) {
      expect(isQnnFp16SupportedSoc(soc), isFalse, reason: soc);
    }
    for (final soc in ['sc8380xp', 'sm8475', 'sm8550', 'sm8650', 'sm8750']) {
      expect(isQnnFp16SupportedSoc(soc), isTrue, reason: soc);
    }
    expect(isQnnFp16SupportedSoc(' QCS6490 '), isFalse);
    expect(isQnnFp16SupportedSoc(null), isTrue);
    expect(isQnnFp16SupportedSoc('unknown'), isTrue);
  });

  test('FP16 unsupported devices offer CPU/GPU but no SDK QNN variants', () {
    const environments = [
      'CPU',
      'CPU-OpenBLAS',
      'GPU-Vulkan',
      'QNN-CPU',
      'QNN-GPU',
      'QNN-HTP'
    ];
    expect(
        environments
            .where((name) => isSdkQnnEnvironmentSelectable(name, 'qcs6490')),
        ['CPU', 'CPU-OpenBLAS', 'GPU-Vulkan']);
    for (final soc in ['sc8380xp', 'unknown', null]) {
      expect(
          environments
              .where((name) => isSdkQnnEnvironmentSelectable(name, soc)),
          ['CPU', 'CPU-OpenBLAS', 'GPU-Vulkan', 'QNN-HTP']);
    }
  });

  test('QCS6490 hides SDK marks and keeps LLM, VLM and ALM marks', () {
    for (final model in modelCatalog) {
      expect(
          showQnnMark(
              qnnSupported: model.qnnSupported,
              usesLlmBackend: model.usesLlmBackend,
              soc: 'qcs6490'),
          model.qnnSupported && model.usesLlmBackend,
          reason: model.id);
      expect(
          showQnnMark(
              qnnSupported: model.qnnSupported,
              usesLlmBackend: model.usesLlmBackend,
              soc: 'sc8380xp'),
          model.qnnSupported,
          reason: model.id);
    }
    for (final id in ['gemma4-e2b', 'gemma4-e2b-vlm', 'gemma4-e2b-alm']) {
      final model = modelCatalog.firstWhere((model) => model.id == id);
      expect(
          showQnnMark(
              qnnSupported: model.qnnSupported,
              usesLlmBackend: model.usesLlmBackend,
              soc: 'qcs6490'),
          isTrue);
    }
  });

  test('FP16 unsupported QCS6490 retains its LLM context binary', () {
    expect(isQnnFp16SupportedSoc('qcs6490'), isFalse);
    expect(qnnTextModelFiles('gemma4-e2b', 'qcs6490'),
        ['gemma/qnn/v1.5.0', 'gemma4-e2b-qcs6490.qnn']);
  });
}
