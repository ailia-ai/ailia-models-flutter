import 'dart:async';
import 'dart:isolate';

import 'tool_use_model.dart';

/// Owns the native model on one isolate for the entire demo session.
class ToolUseWorker {
  ReceivePort? _events;
  SendPort? _commands;
  Completer<void>? _pending;
  void Function(Map<String, dynamic>)? _onEvent;
  bool _disposed = false;

  Future<void> start(String path, String backend) async {
    if (_disposed || _events != null) {
      throw StateError('Worker already started');
    }
    final events = ReceivePort();
    _events = events;
    final ready = Completer<void>();
    _pending = ready;
    events.listen((dynamic value) {
      if (value is SendPort) {
        _commands = value;
        if (_disposed) value.send({'type': 'close'});
        return;
      }
      if (value == null || value is List) {
        final error =
            StateError(value == null ? 'Tool Use worker exited' : '$value');
        _commands = null;
        _disposed = true;
        _fail(error);
        events.close();
        return;
      }
      final event = Map<String, dynamic>.from(value as Map);
      if (event['type'] == 'ready' || event['type'] == 'done') {
        final pending = _pending;
        _pending = null;
        pending?.complete();
      } else if (event['type'] == 'error') {
        _fail(StateError(event['message'] as String));
      } else if (!_disposed) {
        _onEvent?.call(event);
      }
    });
    try {
      await Isolate.spawn(_runToolUse, (events.sendPort, path, backend),
          onError: events.sendPort, onExit: events.sendPort);
    } catch (error) {
      _fail(error);
      events.close();
    }
    await ready.future;
  }

  Future<void> chat(String input, bool thinking,
      void Function(Map<String, dynamic>) onEvent) async {
    if (_disposed || _commands == null || _pending != null) {
      throw StateError('Tool Use worker is unavailable or busy');
    }
    final done = Completer<void>();
    _pending = done;
    _onEvent = onEvent;
    _commands!.send({'type': 'chat', 'input': input, 'thinking': thinking});
    try {
      await done.future;
    } finally {
      _onEvent = null;
    }
  }

  void cancel() => _commands?.send({'type': 'cancel'});
  void clearHistory() => _commands?.send({'type': 'clear'});

  void _fail(Object error) {
    final pending = _pending;
    _pending = null;
    pending?.completeError(error);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _commands?.send({'type': 'close'});
    // The worker closes its native handle after generation has stopped.
    // Keep the event port until exit so any waiting Future is completed.
  }
}

Future<void> _runToolUse((SendPort, String, String) request) async {
  final (events, path, backend) = request;
  final commands = ReceivePort();
  final model = ToolUseModel();
  var busy = false;
  var closing = false;
  void close() {
    try {
      model.close();
    } finally {
      commands.close();
    }
  }

  events.send(commands.sendPort);
  commands.listen((dynamic value) async {
    final command = value as Map;
    switch (command['type']) {
      case 'cancel':
        model.cancel();
      case 'close':
        closing = true;
        model.cancel();
        if (!busy) close();
      case 'clear':
        if (!busy) model.clearHistory();
      case 'chat':
        if (busy || closing) return;
        busy = true;
        try {
          await model.chat(command['input'] as String,
              thinking: command['thinking'] as bool, onEvent: events.send);
          events.send({'type': 'done'});
        } catch (error) {
          events.send({'type': 'error', 'message': '$error'});
        } finally {
          busy = false;
          if (closing) close();
        }
    }
  });
  try {
    model.open(path, backend);
    events.send({'type': 'ready'});
  } catch (error) {
    events.send({'type': 'error', 'message': '$error'});
    commands.close();
  }
}
