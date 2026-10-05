import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'sdxl.dart';

/// Raw RGBA pixels of a generated or preview image. Isolate messages
/// carry pixels in this form so no encode round trip is needed; use
/// [toImage] (or ui.decodeImageFromPixels) on the receiving side.
class SdxlImageData {
  final int width;
  final int height;
  final Uint8List rgba;

  SdxlImageData(this.width, this.height, this.rgba);

  img.Image toImage() => img.Image.fromBytes(
      width: width, height: height, numChannels: 4, bytes: rgba.buffer);

  static SdxlImageData fromImage(img.Image image) => SdxlImageData(
      image.width,
      image.height,
      image.convert(numChannels: 4).getBytes(order: img.ChannelOrder.rgba));
}

typedef SdxlWorkerStatusCallback = Future<void> Function(String status);
typedef SdxlWorkerStepCallback = Future<void> Function(
    int completedSteps, int totalSteps, SdxlImageData? preview);

/// Runs [StableDiffusionXL] on a long-lived background isolate so the
/// multi-second inference calls never block the UI isolate. The models
/// are opened on the worker and stay resident there between runs;
/// status, per-step progress, previews and the result are relayed as
/// isolate messages.
class SdxlWorker {
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _receive;
  Stream<dynamic>? _events;

  bool get started => _isolate != null;

  /// Spawns the worker and opens the tokenizers ([modelDir] as in
  /// [StableDiffusionXL.open]). The networks themselves load lazily on
  /// the worker during the first generation.
  Future<void> start(String modelDir, {int envId = 0}) async {
    if (_isolate != null) {
      return;
    }
    final receive = ReceivePort();
    final events = receive.asBroadcastStream();
    _receive = receive;
    _events = events;
    _isolate = await Isolate.spawn(_sdxlWorkerMain, receive.sendPort,
        onExit: receive.sendPort, onError: receive.sendPort);
    _commands = await events.first as SendPort;

    _commands!.send({'cmd': 'open', 'modelDir': modelDir, 'envId': envId});
    final reply = await events.firstWhere((event) =>
        event is! Map || event['type'] == 'opened' || event['type'] == 'error');
    if (reply is! Map) {
      dispose();
      throw Exception('SDXL worker terminated: $reply');
    }
    if (reply['type'] == 'error') {
      dispose();
      throw Exception(reply['message']);
    }
  }

  Future<SdxlImageData> txt2img({
    required String prompt,
    int width = 1024,
    int height = 1024,
    int steps = 20,
    double guidanceScale = 5.0,
    bool previewEachStep = false,
    SdxlWorkerStepCallback? onStep,
    SdxlWorkerStatusCallback? onStatus,
  }) {
    return _generate({
      'cmd': 'txt2img',
      'prompt': prompt,
      'width': width,
      'height': height,
      'steps': steps,
      'guidanceScale': guidanceScale,
      'previewEachStep': previewEachStep,
    }, onStep, onStatus);
  }

  Future<SdxlImageData> img2img({
    required img.Image image,
    required String prompt,
    int steps = 20,
    double guidanceScale = 5.0,
    double strength = 0.85,
    bool previewEachStep = false,
    SdxlWorkerStepCallback? onStep,
    SdxlWorkerStatusCallback? onStatus,
  }) {
    final input = SdxlImageData.fromImage(image);
    return _generate({
      'cmd': 'img2img',
      'prompt': prompt,
      'inputWidth': input.width,
      'inputHeight': input.height,
      'inputRgba': input.rgba,
      'steps': steps,
      'guidanceScale': guidanceScale,
      'strength': strength,
      'previewEachStep': previewEachStep,
    }, onStep, onStatus);
  }

  Future<SdxlImageData> _generate(
      Map<String, dynamic> command,
      SdxlWorkerStepCallback? onStep,
      SdxlWorkerStatusCallback? onStatus) async {
    final commands = _commands;
    final events = _events;
    if (commands == null || events == null) {
      throw Exception('SdxlWorker is not started');
    }
    commands.send(command);
    await for (final event in events) {
      if (event == null || event is List) {
        // onExit / onError message: the worker is gone.
        throw Exception('SDXL worker terminated: ${event ?? ''}');
      }
      if (event is! Map) {
        continue;
      }
      switch (event['type'] as String) {
        case 'status':
          await onStatus?.call(event['text'] as String);
        case 'step':
          final rgba = event['rgba'] as Uint8List?;
          await onStep?.call(
              event['completed'] as int,
              event['total'] as int,
              rgba == null
                  ? null
                  : SdxlImageData(
                      event['width'] as int, event['height'] as int, rgba));
        case 'result':
          return SdxlImageData(event['width'] as int, event['height'] as int,
              event['rgba'] as Uint8List);
        case 'error':
          if (event['cancelled'] == true) {
            throw SdxlCancelledException();
          }
          throw Exception(event['message']);
      }
    }
    throw Exception('SDXL worker terminated unexpectedly');
  }

  /// Aborts the running generation at the next stage or sampling step
  /// boundary; the aborted call throws [SdxlCancelledException].
  void cancel() {
    _commands?.send({'cmd': 'cancel'});
  }

  /// Cancels any running generation and shuts the worker down (the
  /// worker closes its models and exits on its own).
  void dispose() {
    _commands?.send({'cmd': 'close'});
    _commands = null;
    _receive?.close();
    _receive = null;
    _events = null;
    _isolate = null;
  }
}

Future<void> _sdxlWorkerMain(SendPort events) async {
  final commands = ReceivePort();
  events.send(commands.sendPort);

  final sdxl = StableDiffusionXL();
  bool generating = false;
  bool closeRequested = false;

  void closeAndExit() {
    sdxl.close();
    commands.close();
  }

  Future<void> onStatus(String status) async {
    events.send({'type': 'status', 'text': status});
    // Yield to the worker's event loop so queued cancel / close
    // commands are handled between the blocking inference calls.
    await Future.delayed(Duration.zero);
  }

  Future<void> onStep(
      int completedSteps, int totalSteps, img.Image? preview) async {
    final data = preview == null ? null : SdxlImageData.fromImage(preview);
    events.send({
      'type': 'step',
      'completed': completedSteps,
      'total': totalSteps,
      'width': data?.width,
      'height': data?.height,
      'rgba': data?.rgba,
    });
    await Future.delayed(Duration.zero);
  }

  Future<void> generate(Map message) async {
    generating = true;
    try {
      img.Image result;
      if (message['cmd'] == 'txt2img') {
        result = await sdxl.txt2img(
          prompt: message['prompt'] as String,
          width: message['width'] as int,
          height: message['height'] as int,
          steps: message['steps'] as int,
          guidanceScale: message['guidanceScale'] as double,
          previewEachStep: message['previewEachStep'] as bool,
          onStep: onStep,
          onStatus: onStatus,
        );
      } else {
        final input = SdxlImageData(
                message['inputWidth'] as int,
                message['inputHeight'] as int,
                message['inputRgba'] as Uint8List)
            .toImage();
        result = await sdxl.img2img(
          image: input,
          prompt: message['prompt'] as String,
          steps: message['steps'] as int,
          guidanceScale: message['guidanceScale'] as double,
          strength: message['strength'] as double,
          previewEachStep: message['previewEachStep'] as bool,
          onStep: onStep,
          onStatus: onStatus,
        );
      }
      final data = SdxlImageData.fromImage(result);
      events.send({
        'type': 'result',
        'width': data.width,
        'height': data.height,
        'rgba': data.rgba,
      });
    } on SdxlCancelledException {
      events.send(
          {'type': 'error', 'cancelled': true, 'message': 'cancelled'});
    } catch (e) {
      events.send({'type': 'error', 'cancelled': false, 'message': '$e'});
    } finally {
      generating = false;
      if (closeRequested) {
        closeAndExit();
      }
    }
  }

  commands.listen((message) {
    if (message is! Map) {
      return;
    }
    switch (message['cmd'] as String) {
      case 'open':
        try {
          sdxl.open(message['modelDir'] as String,
              envId: message['envId'] as int);
          events.send({'type': 'opened'});
        } catch (e) {
          events.send({'type': 'error', 'cancelled': false, 'message': '$e'});
        }
      case 'txt2img':
      case 'img2img':
        // Not awaited: the listener stays free to handle cancel/close
        // while the generation runs. The caller sends one generation
        // at a time.
        generate(message);
      case 'cancel':
        sdxl.cancel();
      case 'close':
        if (generating) {
          // Let the running generation abort at its next boundary,
          // then close the models.
          closeRequested = true;
          sdxl.cancel();
        } else {
          closeAndExit();
        }
    }
  });
}
