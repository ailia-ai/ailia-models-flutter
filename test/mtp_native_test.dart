// Opt-in MTP smoke test with the SDK library on the platform's library
// search path. Point AILIA_MODEL_DIR at the app's downloaded models
// (gemma-4-E2B-it-Q4_K_M.gguf, gemma-4-E2B-it-mmproj-F16.gguf,
// mtp-gemma-4-E2B-it-Q4_0.gguf, sample_image.jpg) and optionally
// AILIA_MTP_BACKEND (default CPU) and AILIA_MTP_AUDIO (a 16 kHz WAV).
// On macOS, set DYLD_LIBRARY_PATH to the built app's Contents/Frameworks
// and launch Flutter via the Dart binary (see tool_use_native_test.dart).
import 'dart:io';

import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:ailia_models_flutter/large_language_model/large_language_model.dart';
import 'package:ailia_models_flutter/large_language_model/multimodal_large_language_model.dart';
import 'package:ailia_models_flutter/large_language_model/mtp.dart';
import 'package:ailia_models_flutter/large_language_model/tool_use_model.dart';
import 'package:ailia_models_flutter/large_language_model/tool_use_worker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final dir = Platform.environment['AILIA_MODEL_DIR'];
  final requested = Platform.environment['AILIA_MTP_BACKEND'] ?? 'CPU';
  final audio = Platform.environment['AILIA_MTP_AUDIO'];
  final skip = dir == null ? 'AILIA_MODEL_DIR is not set' : null;
  String path(String name) => '$dir/$name';
  String backend() => AiliaLLMModel.getBackendList()
      .firstWhere((n) => n == requested || n.startsWith('$requested:'));
  String assistant(String type) => path(mtpAssistantFiles(type)[1]);

  for (final mtp in [false, true]) {
    test('Chat generates with MTP ${mtp ? 'on' : 'off'}', () async {
      final llm = LargeLanguageModel();
      try {
        llm.openWithBackendName(
            File(path('gemma-4-E2B-it-Q4_K_M.gguf')), backend(),
            mtpAssistant: mtp ? File(assistant('gemma4-e2b')) : null);
        expect(llm.mtpError, isNull);
        llm.setSystemPrompt('あなたは親切なアシスタントです。');
        var tokens = 0;
        final watch = Stopwatch()..start();
        final text =
            await llm.chatStream('日本の四季について3文で説明してください。', (_) => tokens++);
        final tps = tokens / watch.elapsedMilliseconds * 1000;
        // Second turn reuses the MTP state across prompts.
        final second = await llm.chatStream('一番好きな季節は？', (_) {});
        // ignore: avoid_print
        print('[chat mtp=$mtp] ${tps.toStringAsFixed(1)} tok/s\n$text\n'
            '--- 2nd turn ---\n$second');
        expect(text.trim(), isNotEmpty);
        expect(second.trim(), isNotEmpty);
      } finally {
        llm.close();
      }
    }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));
  }

  test('Tool Use calls the tool with MTP on', () async {
    final worker = ToolUseWorker();
    try {
      await worker.start(path(ToolUseModel.modelFile), backend(),
          mtpPath: assistant('gemma4-e2b-tool-use'));
      expect(worker.mtpError, isNull);
      for (final thinking in [false, true]) {
        double? temperature;
        var answer = '';
        await worker.chat('エアコンの温度を22度にしてください', thinking, (event) {
          if (event['type'] == 'tool') {
            temperature = event['temperature'] as double?;
          }
          if (event['type'] == 'turnComplete') {
            answer = event['content'] as String;
          }
        });
        // ignore: avoid_print
        print('[tool use mtp thinking=$thinking] $temperature: $answer');
        expect(temperature, 22);
        worker.clearHistory();
      }
    } finally {
      worker.dispose();
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 5)));

  const imageQuery = 'この画像を簡潔に説明してください。';
  const audioQuery = 'この音声を日本語で文字起こししてください。';

  /// Runs [runs] of (type, mtp, follow-up) back to back on one worker.
  /// A null follow-up sends a new image / recording, which must not leak
  /// the previous media; otherwise a text-only question continues the
  /// conversation and must be answered from the earlier media.
  Future<void> media(List<(String, bool, String?)> runs) async {
    final model = MultimodalLargeLanguageModel();
    try {
      for (final (type, mtp, followUp) in runs) {
        String? error = 'not loaded';
        double? tps;
        double? ttft;
        final modelFile = File(path('gemma-4-E2B-it-Q4_K_M.gguf'));
        final mmproj = File(path('gemma-4-E2B-it-mmproj-F16.gguf'));
        final mtpFile = mtp ? File(assistant(type)) : null;
        void loaded(String? e) => error = e;
        void metrics(double? first, double? t) {
          ttft = first;
          tps = t;
        }

        final isAudio = type == 'gemma4-e2b-alm';
        final text = isAudio
            ? await model.chatWithAudioIsolate(
                model: modelFile,
                mmproj: mmproj,
                backend: backend(),
                nCtx: 16384,
                systemPrompt: '',
                inputText: followUp ?? audioQuery,
                audioPath: followUp == null ? audio! : null,
                mtpAssistant: mtpFile,
                onModelLoaded: loaded,
                onMetrics: metrics)
            : await model.chatWithImageIsolate(
                model: modelFile,
                mmproj: mmproj,
                backend: backend(),
                nCtx: 16384,
                systemPrompt: '',
                inputText: followUp ?? imageQuery,
                imagePath: followUp == null ? path('sample_image.jpg') : null,
                mtpAssistant: mtpFile,
                onModelLoaded: loaded,
                onMetrics: metrics);
        // ignore: avoid_print
        print('[$type mtp=$mtp ${followUp ?? 'media'}] '
            'TTFT ${ttft?.round()} ms, ${tps?.toStringAsFixed(1)} tok/s '
            '${mtpStatusText(requested: mtp, error: error)}\n$text');
        expect(error, isNull);
        if (followUp == null) {
          // demo.wav is about stew; the sample image shows a Ferris wheel.
          // Within a longer conversation the model may translate it.
          expect(
              text,
              isAudio
                  ? matches(RegExp('stew|煮込み|シチュー', caseSensitive: false))
                  : contains('観覧車'));
        } else {
          expect(
              text,
              matches(isAudio
                  ? RegExp(
                      'カブ|蕪|かぶ|turnip|人参|にんじん|ニンジン|carrot|'
                      'じゃがいも|ジャガイモ|potato',
                      caseSensitive: false)
                  : RegExp('青|ブルー|blue|花', caseSensitive: false)));
        }
      }
    } finally {
      model.close();
    }
  }

  const imageFollowUp = '女性の服は何色ですか？';
  const audioFollowUp = 'その音声に出てくる野菜を挙げてください。';

  final audioSkip =
      skip ?? (audio == null ? 'AILIA_MTP_AUDIO is not set' : null);

  test('VLM continues the conversation and switches MTP', () async {
    await media([
      ('gemma4-e2b-vlm', true, null),
      ('gemma4-e2b-vlm', true, imageFollowUp),
      ('gemma4-e2b-vlm', true, null),
      ('gemma4-e2b-vlm', false, null),
      ('gemma4-e2b-vlm', false, imageFollowUp),
    ]);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 10)));

  test('ALM continues the conversation and switches MTP', () async {
    await media([
      ('gemma4-e2b-alm', true, null),
      ('gemma4-e2b-alm', true, audioFollowUp),
      ('gemma4-e2b-alm', false, null),
      ('gemma4-e2b-alm', false, audioFollowUp),
    ]);
  }, skip: audioSkip, timeout: const Timeout(Duration(minutes: 10)));

  for (final mtp in [true, false]) {
    test('image and audio alternate in one conversation with MTP $mtp',
        () async {
      await media([
        ('gemma4-e2b-vlm', mtp, null),
        ('gemma4-e2b-alm', mtp, null),
        ('gemma4-e2b-vlm', mtp, null),
        ('gemma4-e2b-alm', mtp, null),
      ]);
    }, skip: audioSkip, timeout: const Timeout(Duration(minutes: 10)));
  }
}
