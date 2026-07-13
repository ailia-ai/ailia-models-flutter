import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'demo_session.dart';

/// Meeting-minutes style transcript of speech recognition results,
/// with copy and clear actions. Hidden while empty.
class TranscriptView extends StatelessWidget {
  const TranscriptView({
    super.key,
    required this.lines,
    this.clearEnabled = true,
    required this.onClear,
  });

  final List<String> lines;

  /// Clearing is disabled while recognition is running.
  final bool clearEnabled;

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    if (lines.isEmpty) {
      return const SizedBox.shrink();
    }
    return DemoPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Transcript', style: Theme.of(context).textTheme.labelLarge),
              const Spacer(),
              IconButton(
                tooltip: 'Copy transcript',
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: lines.join('\n')));
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                      content: Text('Transcript copied to clipboard.')));
                },
                icon: const Icon(Icons.copy, size: 20),
              ),
              IconButton(
                tooltip: 'Clear transcript',
                onPressed: clearEnabled ? onClear : null,
                icon: const Icon(Icons.delete_sweep, size: 20),
              ),
            ],
          ),
          for (final line in lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: SelectableText(line),
            ),
        ],
      ),
    );
  }
}
