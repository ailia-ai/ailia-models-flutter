/// Port of VoiceAgentTextStream.kt. Previews never expose partial control syntax.
class VoiceAgentTextStream {
  VoiceAgentTextStream({this.trimLeading = true});
  final bool trimLeading;
  final _raw = StringBuffer();
  static const markers = [
    '<|tool_call>',
    '<tool_call|>',
    '<|tool_response>',
    '<tool_response|>',
    '<|channel>',
    '<channel|>',
    '<|turn>',
    '<turn|>',
    '<eos>',
    '<think>',
  ];

  String append(String delta) {
    _raw.write(delta);
    final text = _raw.toString();
    var end = text.length;
    for (final marker in markers) {
      final index = text.indexOf(marker);
      if (index >= 0 && index < end) end = index;
    }
    var safe = text.substring(0, end);
    final opening = safe.lastIndexOf('<');
    if (opening >= 0 &&
        markers.any((m) => m.startsWith(safe.substring(opening)))) {
      safe = safe.substring(0, opening);
    }
    return trimLeading ? safe.trimLeft() : safe;
  }
}

const _punctuation = '。、！？!?.,，．';
const _closings = '」』）)]】〉》”’"\'';
bool _digit(String c) => RegExp(r'[0-9０-９]').hasMatch(c);
bool _space(String c) => c.trim().isEmpty;
bool _separator(String text, int i) =>
    _punctuation.contains(text[i]) &&
    !('.,，．'.contains(text[i]) &&
        i > 0 &&
        i + 1 < text.length &&
        _digit(text[i - 1]) &&
        _digit(text[i + 1]));

List<String> voiceAgentSpeechSegments(String text) {
  final segments = <String>[];
  var pending = '';
  var boundary = false;
  void flush() {
    final phrase = pending.trim();
    if (RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(phrase)) {
      segments.add(phrase);
    } else if (phrase.isNotEmpty && segments.isNotEmpty) {
      segments[segments.length - 1] += phrase;
    }
    pending = '';
    boundary = false;
  }

  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '\n' || c == '\r') {
      flush();
      continue;
    }
    final separator = _separator(text, i);
    if (boundary && !_space(c) && !separator && !_closings.contains(c)) flush();
    pending += c;
    if (separator) boundary = true;
  }
  flush();
  return segments;
}

/// Cumulative safe previews in, newly completed phrases out. Waits for decimal
/// punctuation and closing quotes even when they arrive in another MTP batch.
class VoiceAgentSpeechText {
  var _consumed = 0;
  List<String> update(String text, {required bool complete}) {
    final pending = text.substring(_consumed.clamp(0, text.length));
    var ready = 0;
    var boundary = false;
    for (var i = 0; i < pending.length; i++) {
      final c = pending[i];
      if (c == '\n' || c == '\r') {
        ready = i + 1;
        boundary = false;
        continue;
      }
      if ('.,，．'.contains(c) &&
          i > 0 &&
          _digit(pending[i - 1]) &&
          i == pending.length - 1 &&
          !complete) {
        break;
      }
      final separator = _separator(pending, i);
      if (boundary && !_space(c) && !separator && !_closings.contains(c)) {
        ready = i;
      }
      if (!_space(c) && !_closings.contains(c)) boundary = separator;
    }
    if (complete) ready = pending.length;
    final result = voiceAgentSpeechSegments(pending.substring(0, ready));
    _consumed = complete ? 0 : _consumed + ready;
    return result;
  }
}
