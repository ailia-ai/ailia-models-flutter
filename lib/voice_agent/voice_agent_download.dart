import 'dart:io';

import 'package:http/http.dart' as http;

import 'voice_agent_config.dart';

/// Session-owned downloads can be stopped immediately, including while waiting
/// for HTTP headers. Partial files never replace shared, completed model files.
class VoiceAgentDownloader {
  VoiceAgentDownloader({http.Client Function()? client})
    : _clientFactory = client ?? http.Client.new;
  final http.Client Function() _clientFactory;
  http.Client? _client;
  bool _cancelled = false;

  void cancel() {
    _cancelled = true;
    _client?.close();
  }

  void _check() {
    if (_cancelled) throw const VoiceAgentCancelled();
  }

  Future<void> download(
    Uri url,
    File file,
    void Function(int, int) progress,
  ) async {
    _check();
    if (await file.exists()) return;
    await file.parent.create(recursive: true);
    _check();
    final partial = File(
      '${file.path}.voice-agent-$pid-${DateTime.now().microsecondsSinceEpoch}.part',
    );
    final client = _clientFactory();
    _client = client;
    IOSink? sink;
    Object? writeError;
    try {
      final response = await client.send(http.Request('GET', url));
      _check();
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}', uri: url);
      }
      sink = partial.openWrite();
      // Observe asynchronous disk errors before the next chunk or final close.
      sink.done.catchError((Object error) {
        writeError = error;
      });
      var bytes = 0;
      await for (final chunk in response.stream) {
        _check();
        if (writeError != null) throw writeError!;
        sink.add(chunk);
        bytes += chunk.length;
        progress(bytes, response.contentLength ?? 0);
      }
      await sink.close();
      sink = null;
      _check();
      if (writeError != null) throw writeError!;
      if (response.contentLength != null && bytes != response.contentLength) {
        throw const HttpException('Incomplete model download');
      }
      if (await file.exists()) {
        await partial.delete();
      } else {
        await partial.rename(file.path);
      }
    } catch (_) {
      _check();
      rethrow;
    } finally {
      client.close();
      _client = null;
      try {
        await sink?.close();
      } finally {
        if (await partial.exists()) await partial.delete();
      }
    }
  }
}
