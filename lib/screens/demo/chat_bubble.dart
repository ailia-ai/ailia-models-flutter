import 'dart:io';

import 'package:flutter/material.dart';

/// One message of a demo conversation. User turns may carry the image or
/// audio that was sent with them.
class ChatTurn {
  ChatTurn.user(this.text, {this.imagePath, this.audioLabel}) : isUser = true;
  ChatTurn.assistant([this.text = ''])
      : isUser = false,
        imagePath = null,
        audioLabel = null;

  final bool isUser;
  String text;
  final String? imagePath;
  final String? audioLabel;
}

/// Chat bubble shared by the LLM / VLM / ALM demos: user messages on the
/// right, replies on the left, newest at the bottom.
class ChatBubble extends StatelessWidget {
  const ChatBubble({super.key, required this.turn});

  final ChatTurn turn;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final imagePath = turn.imagePath;
    final audioLabel = turn.audioLabel;
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (imagePath != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.file(File(imagePath),
                      height: 120, cacheHeight: 240, fit: BoxFit.contain),
                ),
              ),
            if (audioLabel != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.graphic_eq, size: 18),
                  const SizedBox(width: 4),
                  Text(audioLabel),
                ]),
              ),
            SelectableText(turn.text),
          ],
        ),
      ),
    );
  }
}

/// Message box with a send button, used below a conversation.
class ChatInputRow extends StatelessWidget {
  const ChatInputRow({
    super.key,
    required this.controller,
    required this.onSend,
    this.enabled = true,
    this.label = 'Message',
    this.trailing = const [],
  });

  final TextEditingController controller;

  /// Null disables sending (e.g. while generating).
  final VoidCallback? onSend;
  final bool enabled;
  final String label;

  /// Widgets after the send button (e.g. the MTP toggle).
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: controller,
            enabled: enabled,
            decoration: InputDecoration(
              labelText: label,
              border: const OutlineInputBorder(),
            ),
            minLines: 1,
            maxLines: 3,
            onSubmitted: onSend == null ? null : (_) => onSend!(),
          ),
        ),
        const SizedBox(width: 8),
        IconButton.filled(
          tooltip: 'Send',
          onPressed: onSend,
          icon: const Icon(Icons.send),
        ),
        ...trailing,
      ],
    );
  }
}
