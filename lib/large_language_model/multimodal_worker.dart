import 'dart:async';
import 'dart:isolate';

import 'package:ailia_llm/ailia_llm_model.dart';

import 'media_prompt.dart';
import 'qnn_model.dart';

/// Keeps the native model and projector alive across independent media queries.
class MultimodalWorker {
  MultimodalWorker({this.entryPoint = runMultimodalWorker});

  final void Function(SendPort) entryPoint;
  ReceivePort? _events;
  SendPort? _commands;
  Completer<String>? _pending;
  void Function(Map)? _onEvent;

  Future<String> run(Map<String, dynamic> request,
      {void Function(Map)? onEvent}) async {
    if (_pending != null) throw StateError('Media worker is busy');
    final pending = Completer<String>();
    _pending = pending;
    _onEvent = onEvent;
    if (_events == null) {
      final events = ReceivePort();
      _events = events;
      events.listen((dynamic value) {
        // A cancelled worker may still finish opening its native model.
        if (_events != events) {
          if (value is SendPort) value.send(null);
          if (value == null || value is List) events.close();
          return;
        }
        if (value is SendPort) {
          _commands = value;
          value.send(request);
        } else if (value == null || value is List) {
          _fail(StateError('Media worker exited: $value'));
          _events = null;
          _commands = null;
          events.close();
        } else {
          final event = value as Map;
          if (event['type'] == 'done') {
            final done = _pending;
            _pending = null;
            _onEvent = null;
            done?.complete(event['text'] as String);
          } else if (event['type'] == 'error') {
            _fail(StateError(event['message'] as String));
          } else {
            try {
              _onEvent?.call(event);
            } catch (error) {
              _fail(error);
              cancel();
            }
          }
        }
      });
      // Attach the future's consumer before spawn can fail.
      unawaited(Isolate.spawn(entryPoint, events.sendPort,
              onError: events.sendPort, onExit: events.sendPort)
          .then<void>((_) {}, onError: (Object error, StackTrace stack) {
        if (_events == events) {
          _fail(error);
          _events = null;
          _commands = null;
        }
        events.close();
      }));
    } else {
      _commands!.send(request);
    }
    return pending.future;
  }

  void _fail(Object error) {
    final pending = _pending;
    _pending = null;
    _onEvent = null;
    pending?.completeError(error);
  }

  void cancel() {
    _commands?.send(null);
    _commands = null;
    // Keep the old event port until exit, including cancellation during spawn.
    _events = null;
    _fail(StateError('Media inference cancelled'));
  }
}

/// Optional factories allow the real worker lifecycle to be tested without FFI.
void runMultimodalWorker(SendPort events,
    {AiliaLLMModel Function()? modelFactory,
    List<String> Function()? backendList}) {
  final commands = ReceivePort();
  final model = (modelFactory ?? AiliaLLMModel.new)();
  (String, String, String, int)? loaded;
  var busy = false;
  var closing = false;

  void close() {
    try {
      model.close();
    } finally {
      loaded = null;
      commands.close();
    }
  }

  events.send(commands.sendPort);
  commands.listen((dynamic value) async {
    if (value == null) {
      closing = true;
      if (!busy) close();
      return;
    }
    if (busy || closing) return;
    busy = true;
    try {
      final request = value as Map;
      final key = (
        request['modelPath'] as String,
        request['mmprojPath'] as String,
        request['backend'] as String,
        request['nCtx'] as int,
      );
      if (loaded != key) {
        model.close();
        loaded = null;
        events.send({'type': 'loading'});
        llmContextLength(key.$1, key.$3);
        llmContextLength(key.$2, key.$3);
        final backends = (backendList ?? AiliaLLMModel.getBackendList)();
        if (!backends.contains(key.$3)) {
          throw StateError('Backend ${key.$3} not available: $backends');
        }
        model.open(key.$1, key.$4, backend: key.$3);
        model.openMultimodalProjectorFile(key.$2);
        loaded = key;
      }
      final mediaType = request['mediaType'] as String;
      final capability = mediaType == 'audio' ? 'audio' : 'vision';
      if (model.getMultimodalCapabilities()[capability] != true) {
        throw StateError('$capability capabilities not available');
      }
      events.send({'type': 'ready'});
      // Each run supplies a fresh prompt; prior media and answers are omitted.
      final systemPrompt = request['systemPrompt'] as String;
      // Clear native KV cache even when the media path matches the last run.
      model.setPrompt([]);
      model.setPrompt([
        if (systemPrompt.isNotEmpty)
          {'role': 'system', 'content': systemPrompt},
        mediaPromptMessage(request['inputText'] as String,
            request['mediaPath'] as String, mediaType),
      ]);
      final text = StringBuffer();
      await Future<void>.delayed(Duration.zero);
      while (!closing) {
        final delta = model.generate();
        if (delta == null) break;
        text.write(delta);
        events.send({'type': 'delta', 'text': delta});
        await Future<void>.delayed(Duration.zero);
      }
      if (!closing) events.send({'type': 'done', 'text': text.toString()});
    } catch (error) {
      // A failed native operation must not leave a cached, unusable model.
      loaded = null;
      model.close();
      events.send({'type': 'error', 'message': '$error'});
    } finally {
      busy = false;
      if (closing) close();
    }
  });
}
