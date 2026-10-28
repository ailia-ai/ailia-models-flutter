import 'dart:convert';
import 'dart:math';

import 'package:ailia_llm/ailia_llm_model.dart';

import '../large_language_model/tool_use_model.dart';
import 'voice_agent_config.dart';
import 'voice_agent_history.dart';
import 'voice_agent_text.dart';

const _systemPrompt =
    'You are a helpful assistant. Use tools to perform requested actions. '
    'Reply briefly in Japanese after receiving tool results.';
const _continuation =
    ' Continue exactly from the last assistant message. Complete its '
    'unfinished final sentence or line before moving on. Do not repeat, summarize, or restart the answer.';

/// Conversation state survives native model reloads between recognition turns.
class VoiceAgentConversation {
  final List<VoiceMessage> history = [];
  double? temperature;
  static const photoTool = 'take_photo';
  List<VoiceMessage> get tools => [
    ...ToolUseModel.tools.map((t) => jsonDecode(jsonEncode(t)) as VoiceMessage),
    {
      'type': 'function',
      'function': {
        'name': photoTool,
        'description': 'Take one photo using the device camera.',
        'parameters': {'type': 'object', 'properties': <String, dynamic>{}},
      },
    },
  ];

  /// [takePhoto] returns a bounded, upright JPEG as Base64. History owns the
  /// image data independently of temporary camera/preview files.
  Future<String> reply(
    AiliaLLMModel model,
    String input, {
    required int contextSize,
    required int Function() promptTokens,
    required void Function() checkActive,
    required void Function(Map<String, dynamic>) emit,
    required Future<String> Function() takePhoto,
  }) async {
    // Bound ordinary conversation turns as well as token usage.
    while (history.where((m) => m['voice_turn'] == true).length >= 4) {
      history.removeAt(0);
      while (history.isNotEmpty && history.first['voice_turn'] != true) {
        history.removeAt(0);
      }
    }
    final request = <String, dynamic>{
      'role': 'user',
      'content': input,
      'voice_turn': true,
    };
    final beforeTurn = List<VoiceMessage>.of(history);
    history.add(request);
    final photos = <String>[];
    var hasReply = false;
    var partial = '';
    var continued = '';
    var toolRounds = 0;
    var emptyContinuations = 0;
    final definitions = tools;
    if (temperature != null) {
      (definitions.first['function'] as Map)['description'] =
          'エアコンの設定温度を変更します。現在は$temperature度です。';
    }
    model.setTools(definitions);
    model.setThinking(false);
    model.setSamplingParams(40, 0.9, 0, 1234);
    final fixed =
        model.getTokenCount(
          jsonEncode(definitions) + _systemPrompt + _continuation,
        ) +
        64;
    int tokens(VoiceMessage m) {
      if (m['content'] is! List) return model.getTokenCount(jsonEncode(m)) + 32;
      return (m['content'] as List).whereType<Map>().fold(
        32,
        (n, p) =>
            n +
            (p['type'] == 'image'
                ? 512
                : model.getTokenCount('${p['text'] ?? ''}')),
      );
    }

    int historyTokens() => history.fold(0, (n, m) => n + tokens(m));
    void compact({bool activeRequest = false}) {
      final available = max(192, contextSize - fixed - 128);
      final budget = min(available, max(192, historyTokens() ~/ 8));
      request['content'] = input;
      final kept = compactVoiceHistory(
        history,
        budget: budget,
        maximumBudget: emptyContinuations < 2 ? available : budget,
        tokens: tokens,
        request: activeRequest ? request : null,
      );
      history
        ..clear()
        ..addAll(kept);
    }

    void completeInterruptedTools() {
      for (var i = 0; i < history.length; i++) {
        final calls = history[i]['tool_calls'] as List? ?? [];
        final ids = <dynamic>{};
        var position = i + 1;
        while (position < history.length &&
            history[position]['role'] == 'tool') {
          ids.add(history[position]['tool_call_id']);
          position++;
        }
        for (final call in calls) {
          if (!ids.contains(call['id'])) {
            history.insert(position++, {
              'role': 'tool',
              'tool_call_id': call['id'],
              'content': jsonEncode({'error': '操作は中断されました'}),
            });
          }
        }
      }
    }

    void appendPhotos() {
      if (photos.isEmpty) return;
      history.add({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '撮影した写真です。元の依頼に、この写真を踏まえて答えてください。'},
          for (final photo in photos) {'type': 'image', 'data': photo},
        ],
      });
      photos.clear();
    }

    try {
      while (true) {
        checkActive();
        if (fixed + historyTokens() > contextSize - 256) {
          compact(activeRequest: continued.isNotEmpty);
        }
        var complete = false;
        partial = '';
        final preview = VoiceAgentTextStream(trimLeading: continued.isEmpty);
        try {
          model.setPromptJson([
            {
              'role': 'system',
              'content':
                  _systemPrompt + (continued.isEmpty ? '' : _continuation),
            },
            for (final message in history) {...message}..remove('voice_turn'),
          ]);
          final limit = max(0, contextSize - promptTokens() - 16);
          var generated = '';
          for (var step = 0; step < limit; step++) {
            checkActive();
            final delta = model.generate();
            if (model.contextFull()) break;
            if (delta == null) {
              complete = true;
              break;
            }
            generated += delta;
            partial = preview.append(delta);
            emit({
              'type': 'output',
              'text': continued + partial,
              'complete': false,
            });
            final count = model.getTokenCount(generated);
            if (count + 4 >= limit ||
                (count >= limit - max(32, limit ~/ 8) &&
                    RegExp(
                      r'[。！？!?\n\r][」』）)\]】〉》”’"\s]*$',
                    ).hasMatch(partial))) {
              break;
            }
            await Future<void>.delayed(Duration.zero);
          }
        } catch (error) {
          if (!model.contextFull() &&
              !RegExp(
                r'(?:failed:|status[: ]?)\s*-8\b',
                caseSensitive: false,
              ).hasMatch('$error')) {
            rethrow;
          }
        }
        checkActive();
        if (!complete) {
          if (partial.trim().isNotEmpty) {
            hasReply = true;
            history.add({'role': 'assistant', 'content': partial});
            continued += partial;
            partial = '';
            emptyContinuations = 0;
          } else {
            emptyContinuations++;
          }
          if (emptyContinuations > 3) {
            throw StateError('短縮した履歴でもモデルのコンテキストに収まりません');
          }
          compact(activeRequest: continued.isNotEmpty);
          if (continued.isNotEmpty &&
              history.lastOrNull?['content'] != '続けてください') {
            history.add({'role': 'user', 'content': '続けてください'});
          }
          continue;
        }
        final response = model.getResponseJson();
        if (response['role'] != 'assistant') {
          throw const FormatException('Expected an assistant response');
        }
        final calls = (response['tool_calls'] as List? ?? []).map((c) {
          final function = c['function'] as Map;
          final id = c['id'] as String;
          if (id.isEmpty) throw const FormatException('Missing tool call ID');
          return (
            id,
            function['name'] as String,
            function['arguments'] as String,
          );
        }).toList();
        history.add(response);
        hasReply = true;
        partial = '';
        final text = (response['content'] as String? ?? '').trimRight();
        final visible =
            continued + (continued.isEmpty ? text.trimLeft() : text);
        emit({'type': 'output', 'text': visible, 'complete': true});
        if (calls.isEmpty) {
          if (visible.trim().isEmpty) throw StateError('応答が空でした。対話を開始し直してください');
          return visible;
        }
        if (++toolRounds > 8) throw StateError('ツールの呼び出しが上限に達しました');
        for (final (id, name, arguments) in calls) {
          checkActive();
          String result;
          try {
            final args = jsonDecode(arguments);
            if (args is! Map) throw const FormatException('Expected an object');
            switch (name) {
              case ToolUseModel.toolName:
                final value = args['temperature'];
                if (value is! num || !value.isFinite) {
                  throw const FormatException('設定温度は有限の数値で指定してください');
                }
                temperature = value.toDouble();
                emit({'type': 'temperature', 'value': temperature});
                result = jsonEncode({'status': 'ok', 'temperature': value});
              case photoTool:
                photos.add(await takePhoto());
                checkActive();
                result = jsonEncode({'status': 'ok', 'message': '写真を撮影しました。'});
              default:
                result = jsonEncode({'error': 'unknown tool: $name'});
            }
          } on VoiceAgentCancelled {
            rethrow;
          } catch (error) {
            result = jsonEncode({'error': '$error'});
          }
          history.add({'role': 'tool', 'tool_call_id': id, 'content': result});
        }
        appendPhotos();
        continued = '';
        emit({'type': 'output', 'text': '', 'complete': false});
      }
    } catch (error) {
      completeInterruptedTools();
      appendPhotos();
      if (error is VoiceAgentCancelled && partial.trim().isNotEmpty) {
        history.add({'role': 'assistant', 'content': partial.trimRight()});
      } else if (!hasReply) {
        history
          ..clear()
          ..addAll(beforeTurn);
      }
      rethrow;
    }
  }
}
