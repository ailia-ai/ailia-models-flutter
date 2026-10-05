import 'package:flutter_test/flutter_test.dart';
import 'package:ailia_models_flutter/large_language_model/large_language_model.dart';
import 'package:ailia_models_flutter/large_language_model/media_prompt.dart';
import 'package:ailia_models_flutter/large_language_model/multimodal_model_files.dart';
import 'package:ailia_models_flutter/model_catalog.dart';

void main() {
  test('ALM uses microphone audio and the LLM backend selector', () {
    final model = modelCatalog.singleWhere((m) => m.id == 'gemma4-e2b-alm');
    expect(model.category, 'ALM');
    expect(model.input, ModelInputKind.audio);
    expect(model.usesLlmBackend, isTrue);
    expect(model.isChat, isFalse);
  });

  test('ALM and VLM share the GGUF text and audio projector downloads', () {
    expect(multimodalModelFiles('gemma4-e2b-alm'), [
      'gemma',
      'gemma-4-E2B-it-Q4_K_M.gguf',
      'gemma',
      'gemma-4-E2B-it-mmproj-F16.gguf',
    ]);
    expect(multimodalModelFiles('gemma4-e2b-alm'),
        multimodalModelFiles('gemma4-e2b-vlm'));
  });

  test('microphone WAV is sent as audio with the user query', () {
    final message = mediaPromptMessage(
        '文字起こししてください。', r'C:\Temp\mic recording.wav', 'audio');
    expect(message['content'], '文字起こししてください。 <__media__>');
    expect(message['media_data'], [
      {'media_type': 'audio', 'file_path': r'C:\Temp\mic recording.wav'},
    ]);
  });

  test('E4B uses the chat UI and downloads its GGUF', () {
    final model = modelCatalog.singleWhere((m) => m.id == 'gemma4-e4b');
    expect(model.isChat, isTrue);
    expect(model.usesLlmBackend, isTrue);
    expect(LargeLanguageModel().getModelList(model.id),
        ['gemma', 'gemma-4-E4B-it-Q4_K_M.gguf']);
  });
}
