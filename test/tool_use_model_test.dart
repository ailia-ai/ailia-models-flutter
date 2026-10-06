import 'dart:convert';

import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:ailia_models_flutter/large_language_model/tool_use_model.dart';
import 'package:ailia_models_flutter/large_language_model/qnn_model.dart';
import 'package:ailia_models_flutter/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> toolResponse(
        {String name = ToolUseModel.toolName,
        String arguments = '{"temperature":20}',
        String id = 'call-1'}) =>
    {
      'role': 'assistant',
      'content': '',
      'reasoning_content': 'Use the tool.',
      'tool_calls': [
        {
          'id': id,
          'type': 'function',
          'function': {'name': name, 'arguments': arguments}
        }
      ],
    };

class FakeModel extends AiliaLLMModel {
  FakeModel(this.responses);
  final List<Map<String, dynamic>> responses;
  final prompts = <List<Map<String, dynamic>>>[];
  bool full = false;
  bool endless = false;
  bool failParsing = false;
  bool? thinking;
  int _step = 0;
  String? openedPath;
  String? openedBackend;
  int? openedContext;
  List<Map<String, dynamic>>? configuredTools;

  @override
  void open(String modelPath, int nCtx, {String backend = ''}) {
    openedPath = modelPath;
    openedContext = nCtx;
    openedBackend = backend;
  }

  @override
  void setSamplingParams(int topK, double topP, double temperature, int seed) {}

  @override
  void setTools(List<Map<String, dynamic>>? tools) => configuredTools = tools;

  @override
  void close() {}

  @override
  void setThinking(bool enable) => thinking = enable;
  @override
  void setPromptJson(List<Map<String, dynamic>> messages) {
    prompts.add((jsonDecode(jsonEncode(messages)) as List)
        .cast<Map<String, dynamic>>());
    _step = 0;
  }

  @override
  bool contextFull() => full;
  @override
  String? generate() => endless || _step++ == 0 ? 'preview' : null;
  @override
  Map<String, dynamic> getResponseJson() {
    if (failParsing) throw const FormatException('incomplete tool call');
    return responses.removeAt(0);
  }
}

const answer = {'role': 'assistant', 'content': '20度に設定しました。'};

void main() {
  test('Tool Use has a dedicated category and uses LLM backend', () {
    final model =
        modelCatalog.singleWhere((m) => m.id == 'gemma4-e2b-tool-use');
    expect(model.category, 'Tool Use');
    expect(model.usesLlmBackend, isTrue);
    expect(model.isChat, isFalse);
    expect(model.qnnSupported, isTrue);
    expect(model.supportedQnnSocs, windowsQnnSocs);
  });

  test('Tool Use selects the text-only package for each QNN SoC', () {
    for (final soc in windowsQnnSocs) {
      expect(
          ToolUseModel.modelFiles('HTP (QNN): Qualcomm Hexagon HTP', soc: soc),
          ['gemma/qnn/v1.5.0', 'gemma4-e2b-$soc.qnn']);
    }
    for (final backend in ['CPU', 'Metal: Apple GPU', 'Vulkan', 'OpenCL']) {
      expect(ToolUseModel.modelFiles(backend, soc: 'qcs6490'),
          ['gemma', ToolUseModel.modelFile]);
    }
    expect(() => ToolUseModel.modelFiles('HTP'), throwsUnsupportedError);
    expect(() => ToolUseModel.modelFiles('HTP', soc: 'sm7635'),
        throwsUnsupportedError);
  });

  test('HTP opens compiled context while CPU/GPU retains 8192 tokens', () {
    for (final backend in ['HTP (QNN): Qualcomm Hexagon HTP', 'CPU', 'Metal']) {
      final native = FakeModel([]);
      final model = ToolUseModel(model: native, backendList: () => [backend]);
      final files = ToolUseModel.modelFiles(backend, soc: 'sc8380xp');
      model.open(files[1], backend);
      expect(native.openedPath, files[1]);
      expect(native.openedBackend, backend);
      expect(native.openedContext, isLlmQnnBackend(backend) ? 0 : 8192);
      expect(native.configuredTools, ToolUseModel.tools);
    }
  });

  test('mismatched packages and missing backends fail before native open', () {
    final native = FakeModel([]);
    final model =
        ToolUseModel(model: native, backendList: () => ['HTP', 'CPU']);
    expect(() => model.open('model.gguf', 'HTP'), throwsArgumentError);
    expect(() => model.open('model.qnn', 'CPU'), throwsArgumentError);
    expect(() => model.open('model.gguf', 'Metal'), throwsStateError);
    expect(native.openedPath, isNull);
    expect(native.configuredTools, isNull);
  });

  test('structured calls and string tool results round-trip with IDs intact',
      () async {
    final call = toolResponse();
    final native = FakeModel([
      call,
      {...answer},
      {...answer}
    ]);
    final model = ToolUseModel(model: native);
    final events = <Map<String, dynamic>>[];
    expect(await model.chat('20度にして', thinking: true, onEvent: events.add),
        answer['content']);
    expect(native.thinking, isTrue);
    expect(native.prompts[0], [
      {'role': 'user', 'content': '20度にして'}
    ]);
    expect(native.prompts[1][1], call);
    expect(native.prompts[1][2], {
      'role': 'tool',
      'tool_call_id': 'call-1',
      'content': '{"status":"ok","temperature":20}'
    });
    expect(model.airConditionerTemperature, 20);
    expect(events.where((e) => e['type'] == 'turnStart'), hasLength(2));
    expect(events.where((e) => e['type'] == 'tool'), hasLength(1));
    await model.chat('ありがとう', thinking: false, onEvent: (_) {});
    expect(native.prompts.last.length, 5);
    expect(native.prompts.last[3], answer);
  });

  test('all calls in a response receive their matching result', () async {
    final response = toolResponse();
    (response['tool_calls'] as List).addAll(toolResponse(
        id: 'call-2', arguments: '{"temperature":21.5}')['tool_calls'] as List);
    final native = FakeModel([
      response,
      {...answer}
    ]);
    final model = ToolUseModel(model: native);
    await model.chat('change', thinking: false, onEvent: (_) {});
    expect(native.prompts.last[2]['tool_call_id'], 'call-1');
    expect(native.prompts.last[3]['tool_call_id'], 'call-2');
    expect(model.airConditionerTemperature, 21.5);
  });

  for (final arguments in [
    '{}',
    '{',
    '[]',
    '{"temperature":"20"}',
    '{"temperature":null}',
    '{"temperature":1e999}'
  ]) {
    test('invalid arguments return a tool error: $arguments', () async {
      final native = FakeModel([
        toolResponse(arguments: arguments),
        {...answer}
      ]);
      final model = ToolUseModel(model: native);
      await model.chat('change', thinking: false, onEvent: (_) {});
      expect(model.airConditionerTemperature, isNull);
      expect(jsonDecode(native.prompts.last[2]['content'] as String),
          contains('error'));
    });
  }

  test('unknown tool cannot change simulated device', () async {
    final native = FakeModel([
      toolResponse(name: 'run_shell'),
      {...answer}
    ]);
    final model = ToolUseModel(model: native);
    await model.chat('change', thinking: false, onEvent: (_) {});
    expect(model.airConditionerTemperature, isNull);
    expect(native.prompts.last[2]['content'], contains('unknown tool'));
  });

  test('SDK parsing failure executes nothing and rolls back request', () async {
    final native = FakeModel([toolResponse()])..failParsing = true;
    final model = ToolUseModel(model: native);
    await expectLater(model.chat('bad', thinking: false, onEvent: (_) {}),
        throwsFormatException);
    expect(model.airConditionerTemperature, isNull);
    native.failParsing = false;
    native.responses
      ..clear()
      ..add({...answer});
    await model.chat('retry', thinking: false, onEvent: (_) {});
    expect(native.prompts.last, [
      {'role': 'user', 'content': 'retry'}
    ]);
  });

  test('missing call ID is rejected before tool execution', () async {
    final native = FakeModel([toolResponse(id: '')]);
    final model = ToolUseModel(model: native);
    await expectLater(model.chat('bad', thinking: false, onEvent: (_) {}),
        throwsFormatException);
    expect(model.airConditionerTemperature, isNull);
  });

  test('cancellation stops before parsing or executing a tool', () async {
    final native = FakeModel([toolResponse()]);
    final model = ToolUseModel(model: native);
    await expectLater(
        model.chat('cancel', thinking: false, onEvent: (event) {
          if (event['type'] == 'delta') model.cancel();
        }),
        throwsStateError);
    expect(model.airConditionerTemperature, isNull);
    expect(native.responses, hasLength(1));
    native.responses
      ..clear()
      ..add({...answer});
    await model.chat('retry', thinking: false, onEvent: (_) {});
    expect(native.prompts.last, [
      {'role': 'user', 'content': 'retry'}
    ]);
  });

  test('generation step limit and context-full never execute partial calls',
      () async {
    for (final full in [false, true]) {
      final native = FakeModel([toolResponse()])
        ..endless = true
        ..full = full;
      final model = ToolUseModel(model: native);
      await expectLater(
          model.chat('bad',
              thinking: false, onEvent: (_) {}, maxGenerationSteps: 2),
          throwsStateError);
      expect(model.airConditionerTemperature, isNull);
    }
  });

  test('tool turn limit fails and failed request is removed from history',
      () async {
    final native = FakeModel([
      toolResponse(),
      {...answer}
    ]);
    final model = ToolUseModel(model: native);
    await expectLater(
        model.chat('loop', thinking: false, onEvent: (_) {}, maxTurns: 1),
        throwsStateError);
    // Executed actions remain visible even if the follow-up answer fails.
    expect(model.airConditionerTemperature, 20);
    await model.chat('retry', thinking: false, onEvent: (_) {});
    expect(native.prompts.last, [
      {'role': 'user', 'content': 'retry'}
    ]);
  });

  test(
      'clear history retains simulated device state and hides disabled thinking',
      () async {
    final native = FakeModel([
      toolResponse(),
      {...answer},
      {...answer}
    ]);
    final model = ToolUseModel(model: native);
    final events = <Map<String, dynamic>>[];
    await model.chat('change', thinking: false, onEvent: events.add);
    expect(
        events
            .where((e) => e['type'] == 'turnComplete')
            .every((e) => e['reasoning'] == ''),
        isTrue);
    model.clearHistory();
    await model.chat('new', thinking: false, onEvent: (_) {});
    expect(model.airConditionerTemperature, 20);
    expect(native.prompts.last, [
      {'role': 'user', 'content': 'new'}
    ]);
  });
}
