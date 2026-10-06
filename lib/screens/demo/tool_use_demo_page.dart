import 'package:ailia/ailia_license.dart';
import 'package:flutter/material.dart';

import '../../backend_state.dart';
import '../../large_language_model/qnn_runtime.dart';
import '../../large_language_model/tool_use_model.dart';
import '../../large_language_model/tool_use_worker.dart';
import '../../model_catalog.dart';
import 'demo_session.dart';

class ToolUseDemoPage extends StatefulWidget {
  const ToolUseDemoPage({super.key, required this.model});
  final ModelInfo model;

  @override
  State<ToolUseDemoPage> createState() => _ToolUseDemoPageState();
}

class _ToolUseDemoPageState extends State<ToolUseDemoPage>
    with SafeSetStateMixin {
  final _session = DemoSession();
  final _input = TextEditingController(text: ToolUseModel.defaultPrompt);
  final _scroll = ScrollController();
  final _messages = <Map<String, String>>[];
  ToolUseWorker? _worker;
  String? _backend;
  Map<String, String>? _assistant;
  bool _busy = false;
  bool _thinking = false;
  bool _cancelled = false;
  double? _temperature;
  int _lastPaint = 0;

  @override
  void dispose() {
    _worker?.dispose();
    _input.dispose();
    _scroll.dispose();
    _session.dispose();
    super.dispose();
  }

  void _paint() {
    safeSetState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _ensureModel(String backend) async {
    if (_worker != null && _backend == backend) return;
    if (_worker != null) {
      _worker!.dispose();
      _worker = null;
      _messages.clear();
      _temperature = null;
    }
    final files =
        ToolUseModel.modelFiles(backend, soc: availableWindowsQnnSoc());
    await AiliaLicense.checkAndDownloadLicense();
    if (!mounted || _cancelled) return;
    final file = await _session.downloadFile(
        'https://storage.googleapis.com/ailia-models/${files[0]}/${files[1]}',
        files[1]);
    if (!mounted || _cancelled) return;
    if (file == null) throw StateError('Model download failed');
    _session.setStatus('Loading model...');
    final worker = ToolUseWorker();
    _worker = worker;
    try {
      await worker.start(file.path, backend);
      if (!mounted || _cancelled) {
        worker.dispose();
        _worker = null;
        return;
      }
      _backend = backend;
    } catch (_) {
      worker.dispose();
      _worker = null;
      rethrow;
    }
  }

  void _event(Map<String, dynamic> event) {
    if (!mounted) return;
    switch (event['type']) {
      case 'turnStart':
        _assistant = {'role': 'assistant', 'content': ''};
        _messages.add(_assistant!);
        _session.setStatus('Generating...');
      case 'delta':
        _assistant!['content'] = '${_assistant!['content']}${event['text']}';
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now - _lastPaint < 33) return;
        _lastPaint = now;
      case 'turnComplete':
        final text = [
          if ((event['reasoning'] as String).isNotEmpty)
            'Thinking: ${event['reasoning']}',
          if ((event['content'] as String).isNotEmpty)
            event['content'] as String,
        ].join('\n\n');
        if (text.isEmpty) {
          _messages.remove(_assistant);
        } else {
          _assistant!['content'] = text;
        }
        _assistant = null;
      case 'tool':
        _messages.add({
          'role': 'tool',
          'content':
              '${event['name']}(${event['arguments']})\n→ ${event['result']}'
        });
        _temperature = event['temperature'] as double?;
        _session.setStatus('Running tool...');
    }
    _paint();
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    if (_busy || text.isEmpty) return;
    final backend = BackendState.instance.selectedLlmBackend.value;
    safeSetState(() {
      _busy = true;
      _cancelled = false;
    });
    _session.errorText = null;
    _session.showResult('');
    final stopwatch = Stopwatch()..start();
    try {
      await _ensureModel(backend);
      if (!mounted || _cancelled || _worker == null) return;
      _input.clear();
      _messages.add({'role': 'user', 'content': text});
      _paint();
      await _worker!.chat(text, _thinking, _event);
      _session.clearStatus();
      _session
          .showResult('processing time : ${stopwatch.elapsedMilliseconds} ms');
    } catch (error) {
      if (_assistant != null) {
        _messages.remove(_assistant);
        _assistant = null;
      }
      _session.showError(error);
    } finally {
      if (_cancelled) _session.clearStatus();
      safeSetState(() {
        _busy = false;
      });
    }
  }

  void _clear() {
    _worker?.clearHistory();
    safeSetState(_messages.clear);
    _session.errorText = null;
    _session.showResult('');
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DemoPageScaffold(
      model: widget.model,
      session: _session,
      scrollController: _scroll,
      children: [
        DemoPanel(
            child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('エアコンの設定温度を変更するシミュレーションです。'),
            Text(
                _temperature == null
                    ? 'Air conditioner: not set'
                    : 'Air conditioner: ${_temperature!.toStringAsFixed(1)} °C',
                style: Theme.of(context).textTheme.titleMedium),
            Row(children: [
              const Text('Thinking'),
              Switch(
                  value: _thinking,
                  onChanged: _busy
                      ? null
                      : (value) => safeSetState(() {
                            _thinking = value;
                          })),
              const Spacer(),
              IconButton(
                  tooltip: 'Clear conversation',
                  onPressed: _busy || _messages.isEmpty ? null : _clear,
                  icon: const Icon(Icons.delete_sweep)),
            ]),
            for (final message in _messages)
              Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                    color: message['role'] == 'user'
                        ? colors.primaryContainer
                        : message['role'] == 'tool'
                            ? colors.tertiaryContainer
                            : colors.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12)),
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                          message['role'] == 'tool' ? 'Tool' : message['role']!,
                          style: Theme.of(context).textTheme.labelSmall),
                      SelectableText(message['content']!),
                    ]),
              ),
            const SizedBox(height: 8),
            TextField(
                controller: _input,
                minLines: 1,
                maxLines: 3,
                enabled: !_busy,
                decoration: const InputDecoration(
                    labelText: 'Message', border: OutlineInputBorder()),
                onSubmitted: (_) => _send()),
            const SizedBox(height: 8),
            FilledButton.icon(
                onPressed: _busy
                    ? (_cancelled
                        ? null
                        : () {
                            safeSetState(() {
                              _cancelled = true;
                            });
                            _worker?.cancel();
                          })
                    : _send,
                icon: Icon(_busy ? Icons.stop : Icons.send),
                label: Text(_busy ? 'Stop' : 'Send')),
          ],
        ))
      ],
    );
  }
}
