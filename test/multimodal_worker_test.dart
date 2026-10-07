import 'dart:async';
import 'dart:isolate';

import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:ailia_models_flutter/large_language_model/multimodal_worker.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeMediaModel extends AiliaLLMModel {
  FakeMediaModel(this.events);
  final SendPort events;
  int opens = 0;
  String? next;
  bool endless = false;
  bool textPromptSet = false;

  @override
  void open(String path, int nCtx, {String backend = 'CPU'}) {
    opens++;
  }

  @override
  void openMultimodalProjectorFile(String path) {}

  @override
  Map<String, bool> getMultimodalCapabilities() =>
      {'vision': true, 'audio': true};

  @override
  void setPrompt(List<Map<String, dynamic>> messages) {
    if (messages.isEmpty) throw StateError('Empty prompts are unsupported');
    if (messages.length == 1 &&
        messages.single['role'] == 'user' &&
        messages.single['content'] == '.' &&
        !messages.single.containsKey('media_data')) {
      textPromptSet = true;
      next = null;
      endless = false;
      events.send({'type': 'textPromptSet'});
      return;
    }
    if (!textPromptSet) throw StateError('Text prompt was not set first');
    textPromptSet = false;
    events.send({'type': 'promptSet'});
    if (messages.last['content'] == 'fail <__media__>') {
      throw StateError('Failed prompt');
    }
    final media = (messages.last['media_data'] as List).single as Map;
    endless = media['file_path'] == 'endless';
    next = '$opens:${messages.length}:${media['file_path']}';
  }

  @override
  String? generate() {
    if (textPromptSet) throw StateError('Do not generate from the text reset');
    if (endless) return 'token';
    final result = next;
    next = null;
    return result;
  }

  @override
  void close() => events.send({'type': 'closed'});
}

void fakeWorker(SendPort events) => runMultimodalWorker(events,
    modelFactory: () => FakeMediaModel(events),
    backendList: () => ['CPU', 'Metal']);

Map<String, dynamic> request({String media = 'image', String path = 'first'}) =>
    {
      'modelPath': 'model.gguf',
      'mmprojPath': 'projector.gguf',
      'backend': 'CPU',
      'nCtx': 8192,
      'systemPrompt': '',
      'inputText': 'query',
      'mediaPath': path,
      'mediaType': media,
    };

void main() {
  for (final media in ['image', 'audio']) {
    test('$media sets valid text before every media prompt for the same path',
        () async {
      final worker = MultimodalWorker(entryPoint: fakeWorker);
      addTearDown(worker.cancel);
      for (var run = 0; run < 2; run++) {
        final events = <String>[];
        expect(
            await worker.run(request(media: media), onEvent: (event) {
              events.add(event['type'] as String);
            }),
            '1:1:first');
        expect(events.where((e) => e == 'textPromptSet' || e == 'promptSet'),
            ['textPromptSet', 'promptSet']);
      }
    });
  }

  test('image and audio reuse the model and replace the previous prompt',
      () async {
    final worker = MultimodalWorker(entryPoint: fakeWorker);
    addTearDown(worker.cancel);
    final events = <String>[];
    void onEvent(Map event) => events.add(event['type'] as String);
    expect(await worker.run(request(), onEvent: onEvent), '1:1:first');
    expect(events.where((e) => e == 'loading'), hasLength(1));
    expect(events.where((e) => e == 'ready'), hasLength(1));
    expect(events.where((e) => e == 'metrics'), hasLength(1));
    events.clear();
    expect(await worker.run(request(path: 'second'), onEvent: onEvent),
        '1:1:second');
    expect(
        await worker.run(request(media: 'audio', path: 'audio'),
            onEvent: onEvent),
        '1:1:audio');
    expect(events, isNot(contains('loading')));
    expect(events.where((e) => e == 'ready'), hasLength(2));
    expect(events.where((e) => e == 'metrics'), hasLength(2));
  });

  test('reloads for every model configuration change', () async {
    final worker = MultimodalWorker(entryPoint: fakeWorker);
    addTearDown(worker.cancel);
    final input = request();
    expect(await worker.run(input), startsWith('1:'));
    final changes = {
      'modelPath': 'other.gguf',
      'mmprojPath': 'other-projector.gguf',
      'backend': 'Metal',
      'nCtx': 16384
    };
    var count = 1;
    for (final change in changes.entries) {
      input[change.key] = change.value;
      expect(await worker.run(input), startsWith('${++count}:'));
    }
  });

  test('failed inference discards cached native state and can retry', () async {
    final worker = MultimodalWorker(entryPoint: fakeWorker);
    addTearDown(worker.cancel);
    await worker.run(request());
    await expectLater(
        worker.run(request()..['inputText'] = 'fail'), throwsStateError);
    expect(await worker.run(request()), startsWith('2:'));
  });

  test('rejects overlapping requests and settles cancellation during startup',
      () async {
    final worker = MultimodalWorker(entryPoint: fakeWorker);
    addTearDown(worker.cancel);
    final first = worker.run(request());
    final cancelled = expectLater(first, throwsStateError);
    await expectLater(worker.run(request()), throwsStateError);
    worker.cancel();
    await cancelled;
    expect(await worker.run(request()), startsWith('1:'));
  });

  test('close command releases the native model before worker exit', () async {
    final events = ReceivePort();
    final stream = StreamIterator<dynamic>(events);
    await Isolate.spawn(fakeWorker, events.sendPort, onExit: events.sendPort);
    await stream.moveNext();
    final commands = stream.current as SendPort;
    commands.send(request());
    while (await stream.moveNext()) {
      if (stream.current is Map && stream.current['type'] == 'done') break;
    }
    commands.send(null);
    await stream.moveNext();
    expect(stream.current['type'], 'closed');
    await stream.moveNext();
    expect(stream.current, isNull);
    await stream.cancel();
    events.close();
  });

  test('close interrupts ongoing generation and releases the native model',
      () async {
    final events = ReceivePort();
    final stream = StreamIterator<dynamic>(events);
    await Isolate.spawn(fakeWorker, events.sendPort, onExit: events.sendPort);
    await stream.moveNext();
    final commands = stream.current as SendPort;
    commands.send(request(path: 'endless'));
    while (await stream.moveNext()) {
      if (stream.current is Map && stream.current['type'] == 'delta') break;
    }
    commands.send(null);
    var closed = false;
    while (await stream.moveNext()) {
      final event = stream.current;
      if (event == null) break;
      if (event['type'] == 'closed') closed = true;
      expect(event['type'], isNot('done'));
    }
    expect(closed, isTrue);
    await stream.cancel();
    events.close();
  });
}
