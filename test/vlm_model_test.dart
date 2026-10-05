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
    expect(model.getModelList('gemma4-e2b-vlm'), [
      'gemma',
      'gemma-4-E2B-it-Q4_K_M.gguf',
      'gemma',
      'gemma-4-E2B-it-mmproj-F16.gguf',
    ]);
    expect(() => multimodalModelFiles('unknown'), throwsUnsupportedError);
  });

  test('image prompts retain their image dimensions', () {
    expect(
        mediaPromptMessage('Describe', '/image.png', 'image')['media_data'], [
      {
        'media_type': 'image',
        'file_path': '/image.png',
        'width': 0,
        'height': 0
      }
    ]);
  });

  test('rejects unsupported media before calling the native runtime', () {
    expect(
        () => MultimodalLargeLanguageModel().openWithBackendName(
            File('model.gguf'), File('mmproj.gguf'), 'CPU',
            mediaType: 'video'),
        throwsArgumentError);
    expect(() => mediaPromptMessage('Describe', '/video.mp4', 'video'),
        throwsArgumentError);
  });
}
