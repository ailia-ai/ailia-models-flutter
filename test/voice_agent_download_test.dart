import 'dart:async';
import 'dart:io';

import 'package:ailia_models_flutter/voice_agent/voice_agent_config.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_download.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

class DownloadClient extends http.BaseClient {
  DownloadClient(this.response);
  final Future<http.StreamedResponse> response;
  bool closed = false;
  void Function()? onClose;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => response;
  @override
  void close() {
    closed = true;
    onClose?.call();
  }
}

void main() {
  late Directory directory;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('voice-download-');
  });
  tearDown(() {
    directory.deleteSync(recursive: true);
  });
  final url = Uri.parse('https://example.test/model.onnx');

  test('only a completed download becomes a cached model', () async {
    final stream = StreamController<List<int>>();
    final client = DownloadClient(
      Future.value(http.StreamedResponse(stream.stream, 200, contentLength: 3)),
    );
    final file = File('${directory.path}/models/model.onnx');
    final firstChunk = Completer<void>();
    final downloader = VoiceAgentDownloader(client: () => client);
    final download = downloader.download(url, file, (n, total) {
      firstChunk.complete();
    });
    stream.add([1, 2, 3]);
    await firstChunk.future;
    expect(file.existsSync(), isFalse);
    await stream.close();
    await download;
    expect(file.readAsBytesSync(), [1, 2, 3]);
    expect(client.closed, isTrue);
    expect(file.parent.listSync().length, 1);
  });
  test(
    'ending a session aborts HTTP and removes its partial download',
    () async {
      final stream = StreamController<List<int>>();
      final client = DownloadClient(
        Future.value(
          http.StreamedResponse(stream.stream, 200, contentLength: 6),
        ),
      );
      client.onClose = () {
        if (!stream.isClosed) {
          stream.addError(const HttpException('aborted'));
          unawaited(stream.close());
        }
      };
      final file = File('${directory.path}/model.onnx');
      final firstChunk = Completer<void>();
      final downloader = VoiceAgentDownloader(client: () => client);
      final download = downloader.download(url, file, (n, total) {
        firstChunk.complete();
      });
      final expected = expectLater(
        download,
        throwsA(isA<VoiceAgentCancelled>()),
      );
      stream.add([1, 2, 3]);
      await firstChunk.future;
      downloader.cancel();
      await expected.timeout(const Duration(seconds: 2));
      expect(file.existsSync(), isFalse);
      expect(directory.listSync(), isEmpty);
    },
  );
  test(
    'truncated or HTTP error responses never enter the shared cache',
    () async {
      for (final status in [200, 404]) {
        final client = DownloadClient(
          Future.value(
            http.StreamedResponse(
              Stream.value([1]),
              status,
              contentLength: 100,
            ),
          ),
        );
        final downloader = VoiceAgentDownloader(client: () => client);
        final file = File('${directory.path}/model.onnx');
        await expectLater(
          downloader.download(url, file, (_, _) {}),
          throwsA(isA<HttpException>()),
        );
        expect(file.existsSync(), isFalse);
        expect(directory.listSync(), isEmpty);
      }
    },
  );
  test('cached models do not open HTTP or replace existing contents', () async {
    final file = File('${directory.path}/model.onnx')..writeAsBytesSync([7]);
    final downloader = VoiceAgentDownloader(
      client: () => throw StateError('unexpected network request'),
    );
    await downloader.download(url, file, (_, _) {});
    expect(file.readAsBytesSync(), [7]);
  });
}
