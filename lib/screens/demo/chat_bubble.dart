import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One message of a demo conversation. The image or audio sent with a
/// question is already shown on the page, so bubbles hold text only.
class ChatTurn {
  ChatTurn.user(this.text) : isUser = true;
  ChatTurn.assistant([this.text = '']) : isUser = false;

  final bool isUser;
  String text;
}

/// Chat bubble shared by the LLM / VLM / ALM demos: user messages on the
/// right, replies on the left, newest at the bottom.
class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.turn});

  final ChatTurn turn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Align(
      alignment: turn.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        constraints: const BoxConstraints(maxWidth: 400),
        decoration: BoxDecoration(
          color: turn.isUser
              ? scheme.primaryContainer
              : scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
        ),
        child: SelectableText(turn.text),
      ),
    );
  }
}

/// Whether the send shortcut uses Cmd (macOS) rather than Ctrl. Win+Enter
/// is a Windows system shortcut, so other platforms use Ctrl+Enter.
bool get _sendUsesMeta => defaultTargetPlatform == TargetPlatform.macOS;

/// Label of the send shortcut for tooltips.
String get sendShortcutLabel => _sendUsesMeta ? '⌘Enter' : 'Ctrl+Enter';

/// Sends with Cmd+Enter (macOS) or Ctrl+Enter (Windows / Linux) while
/// [child] (a message box) has focus. Null [onSend] disables it.
class SendShortcut extends StatelessWidget {
  const SendShortcut({super.key, required this.onSend, required this.child});

  final VoidCallback? onSend;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final send = onSend;
    return CallbackShortcuts(
      bindings: {
        if (send != null)
          for (final key in [
            LogicalKeyboardKey.enter,
            LogicalKeyboardKey.numpadEnter
          ])
            SingleActivator(key, meta: _sendUsesMeta, control: !_sendUsesMeta):
                send,
      },
      child: child,
    );
  }
}

/// Message box with a send button, used below a conversation. Cmd+Enter
/// (macOS) or Ctrl+Enter (Windows / Linux) sends the message. While a
/// reply is generated, [onStop] turns the send button into a stop button.
class ChatInputRow extends StatelessWidget {
  const ChatInputRow({
    super.key,
    required this.controller,
    required this.onSend,
    this.onStop,
    this.enabled = true,
    this.label = 'Message',
    this.trailing = const [],
  });

  final TextEditingController controller;

  /// Null disables sending (e.g. while generating).
  final VoidCallback? onSend;

  /// Stops the reply being generated; non-null shows the stop button.
  final VoidCallback? onStop;
  final bool enabled;
  final String label;

  /// Widgets after the send button (e.g. the MTP toggle).
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    final send = onSend;
    return Row(
      children: [
        Expanded(
          child: SendShortcut(
            onSend: send,
            child: TextField(
              controller: controller,
              enabled: enabled,
              decoration: InputDecoration(
                labelText: label,
                border: const OutlineInputBorder(),
              ),
              minLines: 1,
              maxLines: 3,
              onSubmitted: send == null ? null : (_) => send(),
            ),
          ),
        ),
        const SizedBox(width: 8),
        if (onStop != null)
          IconButton.filled(
            tooltip: 'Stop',
            onPressed: onStop,
            icon: const Icon(Icons.stop),
          )
        else
          IconButton.filled(
            tooltip: 'Send ($sendShortcutLabel)',
            onPressed: onSend,
            icon: const Icon(Icons.send),
          ),
        ...trailing,
      ],
    );
  }
}
