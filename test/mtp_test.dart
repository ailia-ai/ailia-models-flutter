import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:ailia_models_flutter/large_language_model/mtp.dart';
import 'package:ailia_models_flutter/large_language_model/multimodal_model_files.dart';
import 'package:ailia_models_flutter/large_language_model/tool_use_model.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMtpModel extends AiliaLLMModel {
  String? path;
  int? draft;

  @override
  void openMtpModel(String assistantPath, int nDraft) {
    path = assistantPath;
    draft = nDraft;
    if (assistantPath == 'bad.gguf') throw StateError('Assistant unavailable');
  }
}

void main() {
  test('Gemma 4 models use matching GGUF assistants', () {
    for (final type in [
      'gemma4-e2b',
      'gemma4-e2b-vlm',
      'gemma4-e2b-alm',
      'gemma4-e2b-tool-use',
    ]) {
      expect(supportsMtp(type), isTrue);
      expect(
          mtpAssistantFiles(type), ['gemma', 'mtp-gemma-4-E2B-it-Q4_0.gguf']);
    }
    expect(mtpAssistantFiles('gemma4-e4b'),
        ['gemma', 'mtp-gemma-4-E4B-it-Q4_0.gguf']);
    expect(ToolUseModel.mtpFiles(), mtpAssistantFiles('gemma4-e2b'));
    expect(supportsMtp('gemma2'), isFalse);
    expect(() => mtpAssistantFiles('gemma2'), throwsUnsupportedError);
  });

  test('only supported multimodal models download an optional assistant', () {
    for (final type in ['gemma4-e2b-vlm', 'gemma4-e2b-alm']) {
      final files = multimodalModelFiles(type);
      expect(multimodalModelFiles(type, mtp: true),
          [...files, ...mtpAssistantFiles(type)]);
      expect(files, hasLength(4));
    }
    expect(multimodalModelFiles('gemma3-multimodal', mtp: true),
        multimodalModelFiles('gemma3-multimodal'));
  });

  test('assistant is optional and failure returns a displayable error', () {
    final model = FakeMtpModel();
    expect(openMtpAssistant(model, null), isNull);
    expect(openMtpAssistant(model, ''), isNull);
    expect(model.path, isNull);
    expect(openMtpAssistant(model, 'assistant.gguf'), isNull);
    expect(model.path, 'assistant.gguf');
    expect(model.draft, 3);
    final error = openMtpAssistant(model, 'bad.gguf');
    expect(error, contains('Assistant unavailable'));
    expect(mtpStatusText(requested: true, error: error),
        contains('MTP: unavailable'));
    expect(mtpStatusText(requested: true), 'MTP: on (n_draft=3)');
    expect(mtpStatusText(requested: false), 'MTP: off');
  });
}
