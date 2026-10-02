import 'package:flutter_test/flutter_test.dart';
import 'package:ailia_models_flutter/large_language_model/large_language_model.dart';
import 'package:ailia_models_flutter/large_language_model/media_prompt.dart';
import 'package:ailia_models_flutter/large_language_model/multimodal_model_files.dart';
import 'package:ailia_models_flutter/large_language_model/qnn_model.dart';
import 'package:ailia_models_flutter/model_catalog.dart';

void main() {
  test('ALM uses microphone audio and the LLM backend selector', () {
    final model = modelCatalog.singleWhere((m) => m.id == 'gemma4-e2b-alm');
    expect(model.category, 'ALM');
    expect(model.input, ModelInputKind.audio);
    expect(model.usesLlmBackend, isTrue);
    expect(model.isChat, isFalse);
    expect(model.qnnSupported, isTrue);
  });

  test('ALM downloads the text and audio projector pair on CPU or HTP', () {
    expect(multimodalModelFiles('gemma4-e2b-alm', 'CPU'),
        multimodalModelFiles('gemma4-e2b-vlm', 'CPU'));
    for (final soc in ['sc8380xp', 'qcs6490']) {
      expect(multimodalModelFiles('gemma4-e2b-alm', 'HTP', soc: soc), [
        'gemma/qnn/v1.5.0',
        'gemma4-e2b-$soc.qnn',
        'gemma/qnn/v1.5.0',
        'gemma4-e2b-$soc-mmproj.qnn',
      ]);
    }
  });

  test('microphone WAV is sent as audio with the user query', () {
    final message = mediaPromptMessage(
        '文字起こししてください。', r'C:\Temp\mic recording.wav', 'audio');
    expect(message['content'], '文字起こししてください。 <__media__>');
    expect(message['media_data'], [
      {'media_type': 'audio', 'file_path': r'C:\Temp\mic recording.wav'},
    ]);
    final image = mediaPromptMessage('Describe', 'sample.jpg', 'image');
    expect(image['media_data'][0]['width'], 0);
    expect(() => mediaPromptMessage('', '', 'video'), throwsArgumentError);
  });

  test('E4B selects its GGUF or sc8380xp binary and rejects QCS6490 HTP', () {
    expect(LargeLanguageModel().getModelList('gemma4-e4b', 'CPU'),
        ['gemma', 'gemma-4-E4B-it-Q4_K_M.gguf']);
    expect(qnnTextModelFiles('gemma4-e4b', 'sc8380xp'),
        ['gemma/qnn/v1.5.0', 'gemma4-e4b-sc8380xp.qnn']);
    expect(() => qnnTextModelFiles('gemma4-e4b', 'qcs6490'),
        throwsUnsupportedError);
    final model = modelCatalog.singleWhere((m) => m.id == 'gemma4-e4b');
    expect(model.isChat, isTrue);
    expect(model.supportedQnnSocs, {'sc8380xp'});
  });
}
