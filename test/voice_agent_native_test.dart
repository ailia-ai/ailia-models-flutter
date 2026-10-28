// Opt-in, using cached files and native SDK libraries. See README Voice Agent.
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:ailia/ailia_license.dart';
import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_audio.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_camera.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_speech_turn.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_worker.dart';
import 'package:ailia_models_flutter/utils/qnn_env.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wav/wav.dart';

void main() {
  final root = Platform.environment['AILIA_VOICE_AGENT_MODEL_DIR'];
  test(
    'native structured tools change temperature and retain a photographed image',
    () async {
      final models = VoiceAgentWorker();
      var photos = 0;
      double? temperature;
      try {
        await AiliaLicense.checkAndDownloadLicense();
        await models.start();
        models.takePhoto = () async {
          photos++;
          return voiceAgentPhotoData(
            voiceAgentPhotoJpeg(File('assets/truck.jpg').readAsBytesSync()),
          );
        };
        models.onEvent = (event) {
          if (event['type'] == 'temperature') {
            temperature = (event['value'] as num).toDouble();
          }
        };
        final backend = AiliaLLMModel.getBackendList().firstWhere(
          (b) => b.startsWith(
            Platform.environment['AILIA_VOICE_AGENT_BACKEND'] ?? 'Metal',
          ),
          orElse: () => 'CPU',
        );
        Future<String> reply(String input) async =>
            await models.call('reply', {
                  'input': input,
                  'body': '$root/gemma-4-E2B-it-Q4_K_M.gguf',
                  'projector': '$root/gemma-4-E2B-it-mmproj-F16.gguf',
                  'mtp': '$root/mtp-gemma-4-E2B-it-Q4_0.gguf',
                  'backend': backend,
                })
                as String;
        final changed = await reply('エアコンの温度を20度にしてください。');
        expect(changed, isNotEmpty);
        expect(temperature, 20);
        final described = await reply('写真を撮影してください。この写真に写っているものを一言で教えてください。');
        expect(photos, greaterThan(0));
        expect(described, contains('トラック'));
        final captured = photos;
        final followUp = await reply('その写真の車は何色ですか。');
        expect(followUp, isNotEmpty);
        expect(photos, captured);
        stdout.writeln(
          'Voice Agent tool results: $changed / $described / $followUp',
        );
      } finally {
        await models.close();
      }
    },
    skip: root == null
        ? 'Set AILIA_VOICE_AGENT_MODEL_DIR to run native inference'
        : false,
    timeout: const Timeout(Duration(minutes: 6)),
  );
  test(
    'two synthesized queries pass Silero, Whisper, Gemma and response synthesis',
    () async {
      await AiliaLicense.checkAndDownloadLicense();
      final models = VoiceAgentWorker();
      final voice = VoiceAgentWorker();
      final report = <Map<String, dynamic>>[];
      try {
        await models.start();
        await voice.start();
        final reference = Wav.read(
          File('assets/reference_audio_girl.wav').readAsBytesSync(),
        );
        final voiceArgs = {
          'root': root!,
          'env': cpuEnvironmentId(),
          'rate': reference.samplesPerSecond,
          'channels': reference.channels.length,
          'reference': Float64List.fromList([
            for (var i = 0; i < reference.channels.first.length; i++)
              for (final channel in reference.channels) channel[i],
          ]),
        };
        final backends = AiliaLLMModel.getBackendList();
        final backend = backends.firstWhere(
          (b) => b.startsWith(
            Platform.environment['AILIA_VOICE_AGENT_BACKEND'] ?? 'Metal',
          ),
          orElse: () => 'CPU',
        );
        for (final query in ['自己紹介をしてください。', '一足す一はいくつですか。']) {
          await voice.call('voiceOpen', voiceArgs);
          final audio = VoiceAgentAudio.fromMap(
            await voice.call('synthesize', {'text': query}) as Map,
          );
          expect(audio.pcm, isNotEmpty);
          await voice.call('voiceRelease');
          final previews = <String>[];
          models.onEvent = (event) {
            if (event['type'] == 'input') previews.add(event['text'] as String);
          };
          await models.call('listen', {
            'files': [
              '$root/silero_vad_v6_2.onnx',
              '$root/encoder_turbo.onnx',
              '$root/decoder_turbo_fix_kv_cache.onnx',
            ],
            'env': cpuEnvironmentId(),
            'model': 'whisper_large_v3_turbo',
          });
          final gate = VoiceAgentInputGate(
            audio.sampleRate * audio.channels * 400 ~/ 1000,
          );
          expect(gate.accept(List.filled(gate.remaining, .1)), isEmpty);
          expect(
            await models.call('push', {
              'pcm': Float64List(audio.sampleRate * 12 ~/ 10),
              'rate': audio.sampleRate,
            }),
            isFalse,
          );
          var buffered = false;
          final chunk = audio.sampleRate ~/ 10;
          for (var i = 0; i < audio.pcm.length && !buffered; i += chunk) {
            buffered =
                await models.call('push', {
                  'pcm': audio.pcm.sublist(i, min(audio.pcm.length, i + chunk)),
                  'rate': audio.sampleRate,
                }) ==
                true;
          }
          for (var i = 0; i < 20 && !buffered; i++) {
            buffered =
                await models.call('push', {
                  'pcm': Float64List(chunk),
                  'rate': audio.sampleRate,
                }) ==
                true;
          }
          expect(buffered, isTrue);
          final input = await models.call('recognize') as String;
          expect(input, isNotEmpty);
          var clips = 0;
          final queue = VoiceAgentSpeechQueue(
            worker: voice,
            open: () async {
              await voice.call('voiceOpen', voiceArgs);
            },
            play: (audio) async {
              expect(audio.pcm, isNotEmpty);
              clips++;
            },
            stopPlayback: () async {},
          );
          try {
            models.onEvent = (e) {
              if (e['type'] == 'output') {
                queue.update(
                  e['text'] as String,
                  complete: e['complete'] as bool,
                );
              }
            };
            final output =
                await models.call('reply', {
                      'input': input,
                      'body': '$root/gemma-4-E2B-it-Q4_K_M.gguf',
                      'projector': '$root/gemma-4-E2B-it-mmproj-F16.gguf',
                      'backend': backend,
                      'mtp': '$root/mtp-gemma-4-E2B-it-Q4_0.gguf',
                    })
                    as String;
            expect(output, isNotEmpty);
            expect(output, isNot(contains('<|tool')));
            await queue.finish();
            expect(clips, greaterThan(0));
            report.add({
              'query': query,
              'recognized': input,
              'response': output,
              'previews': previews,
              'clips': clips,
            });
          } finally {
            await queue.close();
          }
        }
      } finally {
        await models.close();
        await voice.close();
        File(
          '${Directory.systemTemp.path}/voice-agent-native.json',
        ).writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report));
      }
    },
    skip: root == null
        ? 'Set AILIA_VOICE_AGENT_MODEL_DIR to run native inference'
        : false,
    timeout: const Timeout(Duration(minutes: 15)),
  );
}
