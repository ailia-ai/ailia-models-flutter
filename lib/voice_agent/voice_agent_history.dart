typedef VoiceMessage = Map<String, dynamic>;

/// Keep tool calls and their results together while retaining the newest suffix.
/// The active request keeps a prefix; oversized answers keep their recent tail.
List<VoiceMessage> compactVoiceHistory(
  List<VoiceMessage> history, {
  required int budget,
  required int maximumBudget,
  required int Function(VoiceMessage) tokens,
  VoiceMessage? request,
}) {
  final requestIndex = request == null ? -1 : history.indexOf(request);
  final messages = request == null
      ? history
      : requestIndex >= 0
      ? history.sublist(requestIndex + 1)
      : history.skipWhile((m) => m['role'] == 'user').toList();
  VoiceMessage? fit(VoiceMessage message, int limit, bool tail) {
    final content = message['content'];
    final text = content is String
        ? content
        : content is List
        ? content
              .whereType<Map>()
              .where((p) => p['type'] == 'text')
              .map((p) => p['text'])
              .join('\n')
        : '';
    if (text.isEmpty) return null;
    final runes = text.runes.toList();
    VoiceMessage bounded(int count) => {
      'role': message['role'],
      'content': String.fromCharCodes(
        tail ? runes.skip(runes.length - count) : runes.take(count),
      ),
    };
    var low = 0;
    var high = runes.length;
    while (low < high) {
      final mid = (low + high + 1) ~/ 2;
      if (tokens(bounded(mid)) <= limit) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low > 0 ? bounded(low) : null;
  }

  final anchor = request == null
      ? null
      : fit(request, messages.isEmpty ? budget : budget ~/ 3, false);
  final anchorCost = anchor == null ? 0 : tokens(anchor);
  final groups = <List<VoiceMessage>>[];
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message['role'] == 'assistant' &&
        (message['tool_calls'] as List? ?? []).isNotEmpty) {
      final group = [message];
      while (i + 1 < messages.length && messages[i + 1]['role'] == 'tool') {
        group.add(messages[++i]);
      }
      groups.add(group);
    } else if (message['role'] != 'tool') {
      groups.add([message]);
    }
  }
  var remaining = budget - anchorCost;
  final kept = <List<VoiceMessage>>[];
  for (final group in groups.reversed) {
    final cost = group.fold(0, (n, m) => n + tokens(m));
    if (cost <= remaining) {
      kept.add(group);
      remaining -= cost;
      continue;
    }
    if (kept.isEmpty &&
        cost <= maximumBudget - anchorCost &&
        (group.length > 1 || group.single['content'] is List)) {
      kept.add(group);
    } else if (group.length == 1 &&
        (group.single['tool_calls'] as List? ?? []).isEmpty) {
      final fitted = fit(group.single, remaining, true);
      if (fitted != null) kept.add([fitted]);
    }
    break;
  }
  // Preserve request identity so later compactions find the same anchor.
  if (anchor != null) request!['content'] = anchor['content'];
  return [if (anchor != null) request!, ...kept.reversed.expand((g) => g)];
}
