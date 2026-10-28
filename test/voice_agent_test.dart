import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:ailia_models_flutter/large_language_model/qnn_model.dart';
import 'package:ailia_models_flutter/model_catalog.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_audio.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_camera.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_config.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_conversation.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_history.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_speech_turn.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_text.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_worker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

class FakeSpeech implements VoiceAgentSpeechEngine {
  final calls = <String>[];
  int buffers = 2;
  bool done = true;
  @override
  void push(List<double> audio, int sampleRate, int channels) =>
      calls.add('push');
  @override
  bool get buffered {
    calls.add('buffered');
    return buffers > 0;
  }

  @override
  void finalize() => calls.add('finalize');
  @override
  List<String> transcribe() {
    calls.add('transcribe');
    buffers--;
    return ['$buffers'];
  }

  @override
  bool get complete {
    calls.add('complete');
    return done;
  }

  @override
  void reset() => calls.add('reset');
}

Map<String, dynamic> tool(
  String name, {
  String id = 'call-1',
  String args = '{}',
}) => {
  'id': id,
  'type': 'function',
  'function': {'name': name, 'arguments': args},
};
Map<String, dynamic> answer(
  String text, [
  List<Map<String, dynamic>> calls = const [],
]) => {
  'role': 'assistant',
  'content': text,
  if (calls.isNotEmpty) 'tool_calls': calls,
};

class FakeLlm extends AiliaLLMModel {
  FakeLlm(this.responses, {this.deltas = const ['はい。']});
  final List<Map<String, dynamic>> responses;
  final List<List<Map<String, dynamic>>> prompts = [];
  List<String> deltas;
  int _step = 0;
  int overflowRounds = 0;
  bool full = false;
  bool failParse = false;
  @override
  void setSamplingParams(int topK, double topP, double temperature, int seed) {}
  @override
  void setThinking(bool enable) {
    expect(enable, isFalse);
  }

  @override
  void setTools(List<Map<String, dynamic>>? tools) {
    expect(tools, hasLength(2));
  }

  @override
  int getTokenCount(String text) => text.runes.length ~/ 8 + 1;
  @override
  void setPromptJson(List<Map<String, dynamic>> messages) {
    prompts.add(
      (jsonDecode(jsonEncode(messages)) as List).cast<Map<String, dynamic>>(),
    );
    _step = 0;
    full = false;
  }

  @override
  String? generate() {
    if (_step < deltas.length) return deltas[_step++];
    full = overflowRounds-- > 0;
    return null;
  }

  @override
  bool contextFull() => full;
  @override
  Map<String, dynamic> getResponseJson() {
    if (failParse) throw const FormatException('bad response');
    return responses.removeAt(0);
  }
}

Future<String> reply(
  VoiceAgentConversation conversation,
  FakeLlm model, {
  String input = 'エアコンを20度にして',
  void Function()? check,
  void Function(Map<String, dynamic>)? emit,
  Future<String> Function()? photo,
}) => conversation.reply(
  model,
  input,
  contextSize: 4096,
  promptTokens: () => 300,
  checkActive: check ?? () {},
  emit: emit ?? (_) {},
  takePhoto: photo ?? () async => 'JPEG',
);

class FakeVoiceWorker extends VoiceAgentWorker {
  final synthesized = <String>[];
  Completer<void>? synthesisGate;
  bool released = false;
  @override
  Future<dynamic> call(
    String method, [
    Map<String, dynamic> args = const {},
  ]) async {
    if (method == 'voiceRelease') {
      released = true;
      return null;
    }
    synthesized.add(args['text'] as String);
    await synthesisGate?.future;
    return {'pcm': Float64List(32), 'rate': 16000, 'channels': 1};
  }

  @override
  void cancel() {}
}

void main() {
  test('Voice Agent appears below Tool Use', () {
    final index = modelCatalog.indexWhere((m) => m.id == 'voice-agent');
    expect(modelCatalog[index - 1].category, 'Tool Use');
    expect(modelCatalog[index].input, ModelInputKind.audio);
  });

  test('MTP defaults match the selected Gemma size', () {
    expect(
      const VoiceAgentConfig(
        speechEnvId: 0,
        voiceEnvId: 0,
        llmBackend: 'CPU',
      ).mtp,
      isTrue,
    );
    expect(
      const VoiceAgentConfig(
        speechEnvId: 0,
        voiceEnvId: 0,
        llmBackend: 'CPU',
        llmModel: 'gemma4-e4b',
      ).mtp,
      isFalse,
    );
  });

  test(
    'input gating drops only playback settling samples, including partial chunks',
    () {
      final gate = VoiceAgentInputGate(5);
      expect(gate.accept([.1, .2, .3]), isEmpty);
      expect(gate.accept([.1, .2, .00001]), [.00001]);
      expect(gate.accept([.00002]), [.00002]);
    },
  );

  for (final model in ['gemma4-e2b', 'gemma4-e4b']) {
    test(
      '$model downloads a matching body, projector and optional assistant',
      () {
        final config = VoiceAgentConfig(
          speechEnvId: 0,
          voiceEnvId: 0,
          llmBackend: 'CPU',
          llmModel: model,
          mtp: true,
        );
        final size = model == 'gemma4-e2b' ? 'E2B' : 'E4B';
        expect(config.llmFiles(), [
          'gemma',
          'gemma-4-$size-it-Q4_K_M.gguf',
          'gemma',
          'gemma-4-$size-it-mmproj-F16.gguf',
          'gemma',
          'mtp-gemma-4-$size-it-Q4_0.gguf',
        ]);
      },
    );
  }
  test('QNN keeps SoC and precision paired and rejects unsupported E4B', () {
    const config = VoiceAgentConfig(
      speechEnvId: 0,
      voiceEnvId: 0,
      llmBackend: 'HTP',
      llmModel: 'gemma4-e4b',
      mtp: true,
    );
    expect(config.llmFiles(soc: 'sc8380xp').where((p) => p.endsWith('.qnn')), [
      'gemma4-e4b-sc8380xp-fp16-mtp.qnn',
      'gemma4-e4b-sc8380xp-fp16-mmproj.qnn',
      'gemma4-e4b-sc8380xp-fp16-mtp-assistant.qnn',
    ]);
    expect(() => config.llmFiles(soc: 'qcs6490'), throwsUnsupportedError);
    final before = qnnModelFormat;
    try {
      qnnModelFormat = QnnModelFormat.v150;
      expect(config.llmFiles(soc: 'sc8380xp'), hasLength(4));
    } finally {
      qnnModelFormat = before;
    }
  });
  test('text-only microphone skips voice; synthetic input still needs it', () {
    expect(
      const VoiceAgentConfig(
        speechEnvId: 0,
        voiceEnvId: 0,
        llmBackend: 'CPU',
        speechOutput: false,
      ).needsVoice,
      isFalse,
    );
    const config = VoiceAgentConfig(
      speechEnvId: 0,
      voiceEnvId: 0,
      llmBackend: 'CPU',
      speechOutput: false,
      testMode: true,
    );
    expect(config.needsVoice, isTrue);
    expect(config.validate, throwsArgumentError);
  });

  test('every control marker stays hidden even across token boundaries', () {
    for (final marker in VoiceAgentTextStream.markers) {
      for (var split = 1; split < marker.length; split++) {
        final stream = VoiceAgentTextStream();
        expect(stream.append(' はい。${marker.substring(0, split)}'), 'はい。');
        expect(stream.append('${marker.substring(split)}secret'), 'はい。');
        expect(stream.append('more'), 'はい。');
      }
    }
    expect(VoiceAgentTextStream().append('1 < 2'), '1 < 2');
  });
  test(
    'speech punctuation preserves decimals, closing quotes, and final tails',
    () {
      const text = '「20.5度です。」次は1,000円です！\nおわり';
      expect(voiceAgentSpeechSegments(text), [
        '「20.5度です。」',
        '次は1,000円です！',
        'おわり',
      ]);
      for (var batch = 1; batch <= text.length; batch++) {
        final stream = VoiceAgentSpeechText();
        final phrases = <String>[];
        for (var i = batch; i < text.length; i += batch) {
          phrases.addAll(stream.update(text.substring(0, i), complete: false));
        }
        phrases.addAll(stream.update(text, complete: true));
        expect(phrases, voiceAgentSpeechSegments(text), reason: 'batch=$batch');
      }
    },
  );
  test('finalize/drain/complete/reset order matches the non-LIVE protocol', () {
    final engine = FakeSpeech();
    final turn = VoiceAgentSpeechTurn(engine);
    expect(turn.push([.01], 16000), isTrue);
    expect(engine.calls, ['push', 'buffered']);
    expect(turn.finish(() {}), ['1', '0']);
    expect(engine.calls, [
      'push',
      'buffered',
      'finalize',
      'buffered',
      'transcribe',
      'buffered',
      'transcribe',
      'buffered',
      'complete',
      'reset',
    ]);
    expect(turn.push([.001], 16000), isFalse);
  });
  test('failed recognition never resets or accepts later chunks', () {
    final engine = FakeSpeech()..done = false;
    final turn = VoiceAgentSpeechTurn(engine);
    expect(() => turn.finish(() {}), throwsStateError);
    expect(engine.calls, isNot(contains('reset')));
    expect(() => turn.push([0], 16000), throwsStateError);
  });

  test(
    'tools use structured calls and preserve IDs, results and photo data',
    () async {
      final conversation = VoiceAgentConversation();
      final native = FakeLlm(
        [
          answer('', [
            tool('set_air_conditioner_temperature', args: '{"temperature":20}'),
            tool('take_photo', id: 'photo'),
          ]),
          answer('20度に設定し、写真を撮影しました。'),
          answer('机が見えます。'),
        ],
        deltas: ['<|tool_', 'call>secret'],
      );
      final events = <Map<String, dynamic>>[];
      expect(
        await reply(conversation, native, emit: events.add),
        contains('撮影'),
      );
      expect(conversation.temperature, 20);
      final prompt = native.prompts[1];
      expect(prompt[1]['content'], 'エアコンを20度にして');
      expect(prompt[3]['tool_call_id'], 'call-1');
      expect(jsonDecode(prompt[3]['content'] as String)['temperature'], 20);
      expect(prompt[4]['tool_call_id'], 'photo');
      expect((prompt[5]['content'] as List).last, {
        'type': 'image',
        'data': 'JPEG',
      });
      expect(
        events
            .where((e) => e['type'] == 'output')
            .every((e) => !(e['text'] as String).contains('secret')),
        isTrue,
      );
      await reply(conversation, native, input: '何が見えますか');
      expect(native.prompts.last.any((m) => m['content'] is List), isTrue);
    },
  );
  for (final args in [
    '{}',
    '[]',
    '{',
    '{"temperature":"20"}',
    '{"temperature":1e999}',
  ]) {
    test(
      'invalid tool arguments become results without changing temperature: $args',
      () async {
        final conversation = VoiceAgentConversation();
        final native = FakeLlm([
          answer('', [tool('set_air_conditioner_temperature', args: args)]),
          answer('失敗しました。'),
        ]);
        await reply(conversation, native);
        expect(conversation.temperature, isNull);
        expect(
          jsonDecode(native.prompts.last[3]['content'] as String),
          contains('error'),
        );
      },
    );
  }
  test(
    'cancellation retains only safe generated text and the recognized request',
    () async {
      final conversation = VoiceAgentConversation();
      final native = FakeLlm(
        [answer('unused')],
        deltas: ['途中。', '<|tool_', 'call>secret'],
      );
      var cancelled = false;
      await expectLater(
        reply(
          conversation,
          native,
          check: () {
            if (cancelled) throw const VoiceAgentCancelled();
          },
          emit: (e) {
            if (e['text'] == '途中。') cancelled = true;
          },
        ),
        throwsA(isA<VoiceAgentCancelled>()),
      );
      expect(conversation.history.last['content'], '途中。');
      expect(conversation.history.first['content'], 'エアコンを20度にして');
    },
  );
  test(
    'cancelling photo resolves all outstanding tool IDs before next prompt',
    () async {
      final conversation = VoiceAgentConversation();
      final native = FakeLlm([
        answer('', [
          tool('take_photo'),
          tool(
            'set_air_conditioner_temperature',
            id: 'other',
            args: '{"temperature":20}',
          ),
        ]),
      ]);
      await expectLater(
        reply(
          conversation,
          native,
          photo: () async => throw const VoiceAgentCancelled(),
        ),
        throwsA(isA<VoiceAgentCancelled>()),
      );
      expect(
        conversation.history
            .where((m) => m['role'] == 'tool')
            .map((m) => m['tool_call_id']),
        ['call-1', 'other'],
      );
      expect(conversation.temperature, isNull);
    },
  );
  test('invalid response envelopes execute nothing', () async {
    final conversation = VoiceAgentConversation();
    final native = FakeLlm([
      answer('', [
        tool(
          'set_air_conditioner_temperature',
          id: '',
          args: '{"temperature":20}',
        ),
      ]),
    ]);
    await expectLater(reply(conversation, native), throwsFormatException);
    expect(conversation.temperature, isNull);
    expect(conversation.history, isEmpty);
  });

  test(
    'interrupted calls are resolved even when a prior turn reused the same ID',
    () async {
      final conversation = VoiceAgentConversation();
      await reply(
        conversation,
        FakeLlm([
          answer('', [
            tool('set_air_conditioner_temperature', args: '{"temperature":20}'),
          ]),
          answer('設定しました。'),
        ]),
      );
      await expectLater(
        reply(
          conversation,
          FakeLlm([
            answer('', [tool('take_photo')]),
          ]),
          photo: () async => throw const VoiceAgentCancelled(),
        ),
        throwsA(isA<VoiceAgentCancelled>()),
      );
      final results = conversation.history
          .where((m) => m['role'] == 'tool')
          .toList();
      expect(results, hasLength(2));
      expect(jsonDecode(results.last['content'] as String), contains('error'));
    },
  );
  test(
    'context overflow continues cumulatively without repeating spoken text',
    () async {
      final conversation = VoiceAgentConversation();
      final native = FakeLlm([answer('続きです。')], deltas: ['はじめ。'])
        ..overflowRounds = 1;
      final stream = VoiceAgentSpeechText();
      final spoken = <String>[];
      final result = await reply(
        conversation,
        native,
        emit: (e) {
          if (e['type'] == 'output') {
            spoken.addAll(
              stream.update(
                e['text'] as String,
                complete: e['complete'] as bool,
              ),
            );
          }
        },
      );
      expect(result, 'はじめ。続きです。');
      expect(spoken, ['はじめ。', '続きです。']);
      expect(native.prompts.last.last['content'], '続けてください');
    },
  );
  test(
    'repeated context rejection terminates rather than looping forever',
    () async {
      final conversation = VoiceAgentConversation();
      final native = FakeLlm([], deltas: [])..overflowRounds = 10;
      await expectLater(reply(conversation, native), throwsStateError);
      expect(native.prompts.length, 4);
    },
  );
  test(
    'history compaction keeps a whole newest tool exchange or discards it',
    () {
      final messages = <VoiceMessage>[
        {'role': 'user', 'content': 'old'},
        answer('', [tool('take_photo')]),
        {'role': 'tool', 'tool_call_id': 'call-1', 'content': 'ok'},
      ];
      final kept = compactVoiceHistory(
        messages,
        budget: 15,
        maximumBudget: 25,
        tokens: (_) => 10,
      );
      expect(kept.map((m) => m['role']), ['assistant', 'tool']);
      expect(
        compactVoiceHistory(
          messages,
          budget: 5,
          maximumBudget: 5,
          tokens: (_) => 10,
        ),
        isEmpty,
      );
    },
  );
  test('history text trimming preserves Unicode and request prefixes', () {
    final request = <String, dynamic>{'role': 'user', 'content': '依頼😀長い依頼'};
    final kept = compactVoiceHistory(
      [request, answer('古い返答😀最近の末尾')],
      budget: 12,
      maximumBudget: 12,
      request: request,
      tokens: (m) => (m['content'] as String).runes.length + 1,
    );
    expect(kept.first['content'], startsWith('依頼'));
    expect(kept.last['content'], endsWith('最近の末尾'));
    expect(jsonEncode(kept), isNot(contains('�')));
  });
  test('photos are upright JPEGs bounded to 512 pixels', () {
    final input = img.Image(width: 1200, height: 800);
    final jpeg = voiceAgentPhotoJpeg(Uint8List.fromList(img.encodePng(input)));
    final output = img.decodeJpg(jpeg)!;
    expect(output.width, 512);
    expect(output.height, 341);
    expect(voiceAgentPhotoData(jpeg), base64Encode(jpeg));
  });
  test(
    'synthesis overlaps generation, holds playback, and bounds queued PCM',
    () async {
      final worker = FakeVoiceWorker();
      final played = <VoiceAgentAudio>[];
      final queue = VoiceAgentSpeechQueue(
        worker: worker,
        open: () async {},
        play: (audio) async {
          played.add(audio);
        },
        stopPlayback: () async {},
      );
      queue.update('一。二。三。四。', complete: true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(worker.synthesized, ['一。', '二。']);
      expect(played, isEmpty);
      await queue.finish().timeout(const Duration(seconds: 2));
      expect(worker.synthesized, ['一。', '二。', '三。', '四。']);
      expect(played, hasLength(4));
      await queue.close();
      expect(worker.released, isTrue);
    },
  );
  test(
    'cancellation waits for native synthesis and discards pending clips',
    () async {
      final worker = FakeVoiceWorker()..synthesisGate = Completer<void>();
      var played = false;
      final queue = VoiceAgentSpeechQueue(
        worker: worker,
        open: () async {},
        play: (_) async {
          played = true;
        },
        stopPlayback: () async {},
      );
      queue.update('一。二。', complete: true);
      await Future<void>.delayed(Duration.zero);
      var joined = false;
      final closing = queue.close().then((_) {
        joined = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(joined, isFalse);
      worker.synthesisGate!.complete();
      await closing.timeout(const Duration(seconds: 2));
      expect(played, isFalse);
      expect(worker.released, isTrue);
    },
  );
  test('voice initialization errors surface and cleanup never hangs', () async {
    final worker = FakeVoiceWorker();
    final queue = VoiceAgentSpeechQueue(
      worker: worker,
      open: () async {
        throw StateError('open failed');
      },
      play: (_) async {},
      stopPlayback: () async {},
    );
    await expectLater(queue.finish(), throwsStateError);
    await queue.close().timeout(const Duration(seconds: 2));
  });
}
