import 'package:ailia/ailia_license.dart';
import 'package:flutter/material.dart';

import '../../backend_state.dart';
import '../../large_language_model/large_language_model.dart';
import '../../model_catalog.dart';
import 'demo_session.dart';

/// Multi-turn chat with a text LLM, streaming the reply into the
/// conversation. The model stays open so the conversation continues
/// across messages.
class ChatDemoPage extends StatefulWidget {
  const ChatDemoPage({super.key, required this.model});

  final ModelInfo model;

  @override
  State<ChatDemoPage> createState() => _ChatDemoPageState();
}

class _ChatDemoPageState extends State<ChatDemoPage> with SafeSetStateMixin {
  final DemoSession _session = DemoSession();
  final ScrollController _scrollController = ScrollController();

  LargeLanguageModel? _llm;
  String? _llmBackend;
  bool _generating = false;
  final List<Map<String, String>> _messages = [];
  final TextEditingController _textController = TextEditingController();
  String _systemPrompt = 'あなたは親切なアシスタントです。';

  @override
  void dispose() {
    _textController.dispose();
    // While a reply is streaming, chatStream still holds the native
    // handle; _sendMessage closes it when the loop ends.
    if (!_generating) {
      _llm?.close();
      _llm = null;
    }
    _scrollController.dispose();
    _session.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  /// Downloads and opens the chat model once; later calls are no-ops so
  /// the conversation continues on the same context.
  Future<void> _ensureModel() async {
    // ailia LLM has its own backend list; use the LLM selection.
    String selectedBackend = BackendState.instance.selectedLlmBackend.value;
    if (_llm != null) {
      if (selectedBackend == _llmBackend) {
        return;
      }
      // Backend changed: reopen the model. The context cannot move
      // between backends, so the conversation starts over.
      _llm!.close();
      _llm = null;
      safeSetState(() {
        _messages.clear();
      });
    }
    await AiliaLicense.checkAndDownloadLicense();
    final llm = LargeLanguageModel();
    final modelList = llm.getModelList(widget.model.id);
    final url =
        "https://storage.googleapis.com/ailia-models/${modelList[0]}/${modelList[1]}";
    final modelFile = await _session.downloadFile(url, modelList[1]);
    if (modelFile == null) {
      throw Exception("Model download failed");
    }
    if (!mounted) {
      // The screen was closed during the download; do not load the model.
      return;
    }

    _session.setStatus("Loading model with selected backend...");
    llm.openWithBackendName(modelFile, selectedBackend);
    if (!mounted) {
      llm.close();
      return;
    }
    llm.setSystemPrompt(_systemPrompt);
    _llm = llm;
    _llmBackend = selectedBackend;
    _session.clearStatus();
    _session.showResult("Model loaded. Enter a message to chat.");
  }

  void _clearChat() {
    safeSetState(() {
      _messages.clear();
    });
    _session.showResult("");
    _llm?.resetHistory();
  }

  Future<void> _editSystemPrompt() async {
    final controller = TextEditingController(text: _systemPrompt);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('System prompt'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (result == null || result.isEmpty || result == _systemPrompt) {
      return;
    }
    safeSetState(() {
      _systemPrompt = result;
      // Changing the prompt starts a fresh conversation.
      _messages.clear();
    });
    _llm?.resetHistory(newSystemPrompt: result);
  }

  Future<void> _sendMessage() async {
    final text = _textController.text.trim();
    if (text.isEmpty || _generating) {
      return;
    }
    _session.errorText = null;
    safeSetState(() {
      _generating = true;
      _textController.clear();
      _messages.add({'role': 'user', 'content': text});
    });
    _scrollToBottom();
    try {
      await _ensureModel();
      if (!mounted || _llm == null) {
        return;
      }
      safeSetState(() {
        _messages.add({'role': 'assistant', 'content': ''});
      });
      int startTime = DateTime.now().millisecondsSinceEpoch;
      // Accumulate tokens and repaint at most once per frame instead of
      // rebuilding the screen per token.
      final reply = StringBuffer();
      int lastPaintMs = 0;
      void paintReply() {
        safeSetState(() {
          _messages.last['content'] = reply.toString();
        });
        _scrollToBottom();
      }

      await _llm!.chatStream(text, (delta) {
        reply.write(delta);
        final nowMs = DateTime.now().millisecondsSinceEpoch;
        if (nowMs - lastPaintMs >= 33) {
          lastPaintMs = nowMs;
          paintReply();
        }
      }, shouldContinue: () => mounted);
      if (mounted) {
        paintReply();
      }
      int endTime = DateTime.now().millisecondsSinceEpoch;
      _session
          .showResult("processing time : ${(endTime - startTime) / 1000} sec");
    } catch (e) {
      _session.showError("Inference Error: $e");
    } finally {
      _generating = false;
      if (mounted) {
        safeSetState(() {});
      } else {
        // The screen was closed while streaming; dispose deferred the
        // close to us.
        _llm?.close();
        _llm = null;
      }
    }
  }

  Widget _buildChatUi() {
    final scheme = Theme.of(context).colorScheme;
    return DemoPanel(
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              IconButton(
                tooltip: 'Edit system prompt',
                onPressed: _generating ? null : _editSystemPrompt,
                icon: const Icon(Icons.tune, size: 20),
              ),
              IconButton(
                tooltip: 'Clear conversation',
                onPressed: _generating || _messages.isEmpty ? null : _clearChat,
                icon: const Icon(Icons.delete_sweep, size: 20),
              ),
            ],
          ),
          for (final message in _messages)
            Align(
              alignment: message['role'] == 'user'
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: Container(
                margin: const EdgeInsets.symmetric(vertical: 4),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                constraints: const BoxConstraints(maxWidth: 400),
                decoration: BoxDecoration(
                  color: message['role'] == 'user'
                      ? scheme.primaryContainer
                      : scheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SelectableText(message['content'] ?? ''),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _textController,
                  decoration: const InputDecoration(
                    labelText: 'Message',
                    border: OutlineInputBorder(),
                  ),
                  minLines: 1,
                  maxLines: 3,
                  onSubmitted: (_) => _sendMessage(),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: _generating ? null : _sendMessage,
                icon: const Icon(Icons.send),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return DemoPageScaffold(
      model: widget.model,
      session: _session,
      scrollController: _scrollController,
      children: [
        _buildChatUi(),
      ],
    );
  }
}
