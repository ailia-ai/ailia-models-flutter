import 'package:ailia_models_flutter/text_to_speech/text_to_speech.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('English text uses the English G2P', () {
    for (final text in [
      'Hello world.',
      "It's 10 o'clock, isn't it?",
      'GPT-SoVITS v2 Pro',
      '  Good morning!\nHow are you? ',
      '“Quoted” — dash',
    ]) {
      expect(TextToSpeech.isEnglishText(text), isTrue, reason: text);
    }
  });

  test('Japanese, Chinese, Korean and mixed text keep the model G2P', () {
    for (final text in [
      'こんにちは。今日はいい天気ですね。',
      'カタカナ',
      '今日はAIの話をします。',
      'Helloと言いました',
      '你好世界。',
      'Hello，world', // full-width comma
      'Ｈｅｌｌｏ', // full-width letters
      '안녕하세요 hello',
      '12345',
      '!?',
      '',
    ]) {
      expect(TextToSpeech.isEnglishText(text), isFalse, reason: text);
    }
  });
}
