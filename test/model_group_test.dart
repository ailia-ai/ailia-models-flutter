import 'package:flutter_test/flutter_test.dart';
import 'package:ailia_models_flutter/model_catalog.dart';

void main() {
  List<String> idsOf(String name) => modelGroups
      .singleWhere((g) => g.name == name)
      .variants
      .map((m) => m.id)
      .toList();

  test('model families share one card', () {
    expect(idsOf('Segment Anything 2 / 3.1'), ['sam2', 'sam3.1']);
    expect(idsOf('Whisper'), [
      'whisper_tiny',
      'whisper_small',
      'whisper_medium',
      'whisper_large_v3_turbo',
    ]);
    expect(idsOf('FuguMT'), ['fugumt-en-ja', 'fugumt-ja-en']);
    expect(idsOf('GPT-SoVITS'), [
      'gpt-sovits-ja',
      'gpt-sovits-en',
      'gpt-sovits-zh',
      'gpt-sovits-v2pro-ja',
    ]);
    expect(idsOf('Gemma 2 / 4'), [
      'gemma2',
      'gemma4-e2b',
      'gemma4-e4b',
    ]);
    expect(idsOf('Gemma 3 / 4'), [
      'gemma3-multimodal',
      'gemma4-e2b-vlm',
    ]);
  });

  test('grouped cards open with their default variant', () {
    String initialOf(String name) =>
        modelGroups.singleWhere((g) => g.name == name).initial.id;
    expect(initialOf('Gemma 2 / 4'), 'gemma4-e2b');
    expect(initialOf('Gemma 3 / 4'), 'gemma4-e2b-vlm');
    expect(initialOf('Whisper'), 'whisper_large_v3_turbo');
    expect(initialOf('GPT-SoVITS'), 'gpt-sovits-v2pro-ja');
    expect(initialOf('Segment Anything 2 / 3.1'), 'sam3.1');
    expect(initialOf('FuguMT'), 'fugumt-en-ja');
    for (final g in modelGroups) {
      expect(g.variants.where((m) => m.groupDefault).length, lessThan(2),
          reason: g.name);
    }
  });

  test('every model is on exactly one card of a single category', () {
    final ids = [for (final g in modelGroups) ...g.variants.map((m) => m.id)];
    expect(ids, modelCatalog.map((m) => m.id).toList());
    for (final g in modelGroups) {
      expect(g.variants.map((m) => m.category).toSet(), {
        g.category,
      }, reason: g.name);
      expect(g.variants.map((m) => groupOf(m)), everyElement(same(g)));
    }
    expect(idsOf('SenseVoice Small'), ['sensevoice_small']);
    expect(idsOf('Gemma 4 E2B ALM'), ['gemma4-e2b-alm']);
  });
}
