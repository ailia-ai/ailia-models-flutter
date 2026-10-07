import 'dart:convert';

import 'package:ailia_llm/ailia_llm_model.dart';

import 'generation_metrics.dart';

/// Gemma 4 tool-use conversation, following AiliaToolUseSample.kt.
/// Only the simulated air conditioner below can be changed by this demo.
class ToolUseModel {
  ToolUseModel({AiliaLLMModel? model}) : _model = model ?? AiliaLLMModel();

  static const modelFile = 'gemma-4-E2B-it-Q4_K_M.gguf';
  static const defaultPrompt = 'エアコンの温度を20度にしてください';
  static const toolName = 'set_air_conditioner_temperature';
  static const tools = <Map<String, dynamic>>[
    {
      'type': 'function',
      'function': {
        'name': toolName,
        'description': 'エアコンの設定温度を変更します。',
        'parameters': {
          'type': 'object',
          'properties': {
            'temperature': {'type': 'number', 'description': '設定温度(摂氏)'},
          },
          'required': ['temperature'],
        },
      },
    },
  ];

  final AiliaLLMModel _model;
  final List<Map<String, dynamic>> _history = [];
  double? airConditionerTemperature;
  bool _busy = false;
  bool _cancelled = false;

  void open(String path, String backend) {
    if (!AiliaLLMModel.getBackendList().contains(backend)) {
      throw StateError('LLM backend unavailable: $backend');
    }
    try {
      _model.open(path, 8192, backend: backend);
      _model.setSamplingParams(40, 0.9, 0.0, 1234);
      _model.setTools(tools);
    } catch (_) {
      close();
      rethrow;
    }
  }

  void cancel() => _cancelled = true;

  void clearHistory() {
    if (_busy) throw StateError('Generation is still running');
    _history.clear();
  }

  String _execute(String name, String arguments) {
    if (name != toolName) return jsonEncode({'error': 'unknown tool: $name'});
    try {
      final args = jsonDecode(arguments);
      final temperature = args is Map ? args['temperature'] : null;
      if (temperature is! num || !temperature.isFinite) {
        throw const FormatException('temperature must be a finite number');
      }
      airConditionerTemperature = temperature.toDouble();
      return jsonEncode({'status': 'ok', 'temperature': temperature});
    } on FormatException {
      return jsonEncode({'error': 'invalid arguments: $arguments'});
    }
  }

  /// Raw deltas are previews only. Execute tools only after the SDK has
  /// successfully parsed a completed response. Preserve that response verbatim.
  Future<String> chat(String input,
      {required bool thinking,
      required void Function(Map<String, dynamic>) onEvent,
      int maxTurns = 8,
      int maxGenerationSteps = 4096}) async {
    if (_busy) throw StateError('Generation is already running');
    _busy = true;
    _cancelled = false;
    final historySize = _history.length;
    try {
      _model.setThinking(thinking);
      _history.add({'role': 'user', 'content': input});
      for (var turn = 0; turn < maxTurns; turn++) {
        _checkCancelled();
        onEvent({'type': 'turnStart'});
        final timing = GenerationMetrics()..start();
        _model.setPromptJson(_history);
        if (_model.contextFull()) throw StateError('Model context is full');
        var done = false;
        for (var step = 0; step < maxGenerationSteps; step++) {
          _checkCancelled();
          final delta = _model.generate();
          if (_model.contextFull()) throw StateError('Model context is full');
          if (delta == null) {
            done = true;
            break;
          }
          timing.recordToken();
          if (delta.isNotEmpty) onEvent({'type': 'delta', 'text': delta});
          // Receive cancellation between native generation calls in the worker.
          await Future<void>.delayed(Duration.zero);
        }
        _checkCancelled();
        if (!done) {
          throw StateError('Generation exceeded $maxGenerationSteps steps');
        }
        onEvent({
          'type': 'metrics',
          'decodeTokens': timing.decodeTokens,
          'decodeSeconds': timing.decodeSeconds,
        });
        final response = _model.getResponseJson();
        if (response['role'] != 'assistant') {
          throw const FormatException('Expected an assistant response');
        }
        final content = response['content'] as String? ?? '';
        final reasoning = response['reasoning_content'] as String? ?? '';
        final calls = response['tool_calls'] as List? ?? [];
        // Validate all call envelopes before executing any of their actions.
        final validatedCalls = calls.map((value) {
          final call = value as Map;
          final function = call['function'] as Map;
          final id = call['id'] as String;
          final name = function['name'] as String;
          final arguments = function['arguments'] as String;
          if (id.isEmpty) throw const FormatException('Missing tool call ID');
          return (id, name, arguments);
        }).toList();
        _history.add(response);
        onEvent({
          'type': 'turnComplete',
          'content': content,
          'reasoning': thinking ? reasoning : ''
        });
        if (validatedCalls.isEmpty) return content;
        for (final (id, name, arguments) in validatedCalls) {
          _checkCancelled();
          final result = _execute(name, arguments);
          _history.add({'role': 'tool', 'tool_call_id': id, 'content': result});
          onEvent({
            'type': 'tool',
            'name': name,
            'arguments': arguments,
            'result': result,
            'temperature': airConditionerTemperature
          });
        }
      }
      throw StateError('Tool call did not finish in $maxTurns turns');
    } catch (_) {
      _history.removeRange(historySize, _history.length);
      rethrow;
    } finally {
      _busy = false;
    }
  }

  void _checkCancelled() {
    if (_cancelled) throw StateError('Generation cancelled');
  }

  void close() {
    try {
      _model.setTools(null);
    } catch (_) {
      // Opening can fail before the native handle or tool API is available.
    } finally {
      _model.close();
    }
  }
}
