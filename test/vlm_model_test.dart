import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ailia_models_flutter/large_language_model/multimodal_large_language_model.dart';
import 'package:ailia_models_flutter/large_language_model/multimodal_model_files.dart';
import 'package:ailia_models_flutter/large_language_model/media_prompt.dart';
import 'package:ailia_models_flutter/model_catalog.dart';

void main() {
  test('both VLM entries use the LLM selector and image/text input', () {
    final models = modelCatalog.where((model) => model.category == 'VLM');
    expect(models.map((model) => model.id),
        ['gemma3-multimodal', 'gemma4-e2b-vlm']);
    for (final model in models) {
      expect(model.usesLlmBackend, isTrue);
      expect(model.isChat, isFalse);
      expect(model.input, ModelInputKind.imageText);
    }
  });

  test('downloads the matching Gemma 3 and Gemma 4 GGUF projectors', () {
    final model = MultimodalLargeLanguageModel();
    expect(model.getModelList(), [
      'gemma',
      'gemma-3-4b-it-Q4_K_M.gguf',
      'gemma',
      'gemma-3-4b-it-GGUF_mmproj-model-f16.gguf',
    ]);
    expect(model.getModelList('gemma4-e2b-vlm', 'CPU'), [
      'gemma',
      'gemma-4-E2B-it-Q4_K_M.gguf',
      'gemma',
      'gemma-4-E2B-it-mmproj-F16.gguf',
    ]);
    expect(() => multimodalModelFiles('unknown', 'CPU'),
        throwsUnsupportedError);
  });

  test('multimodal context size follows model format and backend', () {
    expect(MultimodalLargeLanguageModel.contextSize(
        'gemma4-e2b-vlm', 'gemma4.gguf', 'CPU'), 16384);
    expect(MultimodalLargeLanguageModel.contextSize(
        'gemma4-e2b-vlm', 'gemma4.qnn', 'HTP'), 0);
    expect(() => MultimodalLargeLanguageModel.contextSize(
        'gemma4-e2b-vlm', 'gemma4.gguf', 'HTP'), throwsArgumentError);
  });

  test('HTP uses matching text and projector packages for each SoC', () {
    for (final soc in ['sc8380xp', 'qcs6490']) {
      expect(
          multimodalModelFiles(
              'gemma4-e2b-vlm', 'HTP (QNN): Qualcomm Hexagon HTP',
              soc: soc),
          [
            'gemma/qnn/v1.5.0',
            'gemma4-e2b-$soc.qnn',
            'gemma/qnn/v1.5.0',
            'gemma4-e2b-$soc-mmproj.qnn',
          ]);
    }
    expect(
        () => multimodalModelFiles('gemma3-multimodal', 'HTP', soc: 'sc8380xp'),
        throwsUnsupportedError);
    expect(() => multimodalModelFiles('gemma4-e2b-vlm', 'HTP', soc: 'sm7635'),
        throwsUnsupportedError);
  });

  test('rejects a mismatched projector before opening the native model', () {
    final model = MultimodalLargeLanguageModel();
    expect(
        () => model.openWithBackendName(
            File('gemma4.qnn'), File('mmproj.gguf'), 'HTP'),
        throwsArgumentError);
    expect(
        () => model.openWithBackendName(
            File('gemma4.gguf'), File('mmproj.qnn'), 'CPU'),
        throwsArgumentError);
  });

  test('image prompt carries image dimensions and rejects video', () {
    final prompt = mediaPromptMessage('Describe', '/image.png', 'image');
    expect(prompt['media_data'], [
      {
        'media_type': 'image',
        'file_path': '/image.png',
        'width': 0,
        'height': 0,
      }
    ]);
    expect(() => mediaPromptMessage('Describe', '/video.mp4', 'video'),
        throwsArgumentError);
  });
}
