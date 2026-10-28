// Whisper Speech To Text Streaming Processing

import 'dart:isolate';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'package:ailia_speech/ailia_speech.dart' as ailia_speech_dart;
import 'package:ailia_speech/ailia_speech_model.dart';
import 'package:ailia/ailia_model.dart';

import '../utils/qnn_env.dart';

void speechToTextIsolateFunc(SendPort initialReplyTo) {
  final receivePort = ReceivePort();
  final interruptPort = ReceivePort();
  initialReplyTo.send({
    "sendPort": receivePort.sendPort,
    "interruptPort": interruptPort.sendPort
  });

  late AiliaSpeechModel ailiaSpeechToText;

  // 終了の割り込みメッセージ
  bool interrupt = false;
  interruptPort.listen((message) {
    interrupt = true;
  });

  // 音声認識ジョブの処理
  receivePort.listen((message) {
    SendPort answerPort = message["answerPort"];

    if (message["cmd"] == "initialize") {
      ailiaSpeechToText = AiliaSpeechModel();
      ailiaSpeechToText.create(
        message["liveTranscribe"],
        false,
        message["envId"],
        virtualMemory:message["virtualMemory"],
      );
      ailiaSpeechToText.open(
        message["encoderFile"],
        message["decoderFile"],
        message["vadEnable"] ? message["vadFile"] : null,
        message["language"],
        message["modelType"],
      );
      if (message["segmentationFile"] != null &&
          message["embeddingFile"] != null) {
        ailiaSpeechToText.diarization(
          message["segmentationFile"],
          message["embeddingFile"],
        );
      }
      return;
    }

    if (message["cmd"] == "terminate") {
      // finalizeInputData closes the sink, so draining with transcribe
      // always reaches the complete flag. The try/finally only protects
      // against exceptions: the finish message must reach the UI or the
      // screen stays on "terminating" forever.
      try {
        ailiaSpeechToText.finalizeInputData();
        while (!ailiaSpeechToText.isComplete() && interrupt == false) {
          var result = ailiaSpeechToText.transcribe();
          if (result.isNotEmpty) {
            answerPort.send({
              "intermediate": false,
              "terminate": false,
              "text": result,
            });
          }
        }
        ailiaSpeechToText.reset();
        ailiaSpeechToText.close();
      } catch (e) {
        print("speech terminate error: $e");
      } finally {
        answerPort.send({
          "intermediate": false,
          "terminate": true,
          "text": null,
        });
      }
      return;
    }

    if (message["cmd"] == "transcribe") {
      void intermediateCallback(textMessage) {
        SpeechText text = SpeechText(
          textMessage,
          0,
          0,
          0,
          0,
        );
        List<SpeechText> result = [text];
        answerPort.send({
          "intermediate": true,
          "terminate": false,
          "text": result,
        });
      }

      try {
        ailiaSpeechToText.setIntermediateCallback(intermediateCallback);

        ailiaSpeechToText.pushInputData(
          message["chunk"],
          message["sampleRate"],
          message["channels"],
        );

        while (ailiaSpeechToText.isBuffered() && interrupt == false) {
          var result = ailiaSpeechToText.transcribe();
          if (result.isNotEmpty) {
            answerPort.send({
              "intermediate": false,
              "terminate": false,
              "text": result,
            });
          }
        }
      } catch (e) {
        // A failed chunk must not kill the isolate's message loop.
        print("speech transcribe error: $e");
      } finally {
        // The caller sends the audio captured meanwhile as the next batch.
        answerPort.send({"drained": true});
      }
      return;
    }

    print("unknown cmd");
  });
}

class SpeechToTextIsolate {
  late ReceivePort receivePort;
  late Isolate isolate;
  late SendPort sendPort;
  late SendPort interruptPort;
  late ReceivePort answerPort;
  bool _isTerminateFlag = false;
  bool _isInitializeFlag = false;
  bool _isIntermediateFlag = false;
  bool _isInterruptFlag = false;

  // 認識中に届いたマイク音声。isolateが認識を終えるたびに次のバッチとして送る
  final List<List<double>> _pendingChunks = [];
  int _pendingSampleRate = 0;
  int _pendingChannels = 0;
  bool _draining = false;

  Future<void> init(
    Function intermediateCallback,
    Function messageCallback,
    Function finishCallback,
    File encoderFile,
    File decoderFile,
    File vadFile,
    int modelType,
    bool liveTranscribe,
    String language,
    bool vadEnable,
    int envId,
    bool virtualMemory,
    File? segmentationFile,
    File? embeddingFile,
  ) async {
    _isTerminateFlag = false;
    _isInterruptFlag = false;
    _pendingChunks.clear();
    _draining = false;
    receivePort = ReceivePort();
    isolate = await Isolate.spawn(
      speechToTextIsolateFunc,
      receivePort.sendPort,
    );
    var message = await receivePort.first;
    sendPort = message["sendPort"] as SendPort;
    interruptPort = message["interruptPort"] as SendPort;
    answerPort = ReceivePort();
    answerPort.listen((message) async {
      if (message["drained"] == true) {
        _onDrained();
        return;
      }
      if (message["intermediate"] == true) {
        _isIntermediateFlag = true;
        intermediateCallback(message["text"]);
      } else {
        if (message["terminate"] == true) {
          finishCallback();
        } else {
          messageCallback(message["text"]);
        }
      }
    });

    var args = {
      "answerPort": answerPort.sendPort,
      "cmd": "initialize",
      "encoderFile": encoderFile,
      "decoderFile": decoderFile,
      "vadFile": vadFile,
      "liveTranscribe": liveTranscribe,
      "language": language,
      "modelType": modelType,
      "vadEnable": vadEnable,
      "envId": envId,
      "virtualMemory": virtualMemory,
      "segmentationFile": segmentationFile,
      "embeddingFile": embeddingFile,
    };
    sendPort.send(args);

    _isInitializeFlag = true;
    _isIntermediateFlag = false;
  }

  void send(List<double> chunk, int sampleRate, int channels) {
    if (!_isInitializeFlag) {
      print("Warning : send : not initialized");
      return;
    }

    if (_isTerminateFlag) {
      return;
    }

    // 認識中に届いた音声は溜めておき、認識完了後にまとめてpushする
    _pendingChunks.add(chunk);
    _pendingSampleRate = sampleRate;
    _pendingChannels = channels;
    if (_draining) {
      return;
    }
    _draining = true;
    _sendPendingBatch();
  }

  void _sendPendingBatch() {
    int length = 0;
    for (final chunk in _pendingChunks) {
      length += chunk.length;
    }
    final batch = Float64List(length);
    int offset = 0;
    for (final chunk in _pendingChunks) {
      batch.setAll(offset, chunk);
      offset += chunk.length;
    }
    _pendingChunks.clear();
    var args = {
      "answerPort": answerPort.sendPort,
      "cmd": "transcribe",
      "chunk": batch,
      "sampleRate": _pendingSampleRate,
      "channels": _pendingChannels
    };
    sendPort.send(args);
  }

  void _onDrained() {
    if (_pendingChunks.isEmpty || _isTerminateFlag) {
      _draining = false;
      return;
    }
    _sendPendingBatch();
  }

  bool isTerminate() {
    return _isTerminateFlag;
  }

  bool isIntermediate() {
    return _isIntermediateFlag;
  }

  // キューを最後まで処理をして終了する
  void terminate() {
    if (_isTerminateFlag) {
      return;
    }
    if (!_isInitializeFlag) {
      print("Warning : terminate : not initialized");
      return;
    }
    _isTerminateFlag = true;
    // 未処理の音声をすべて投入してから認識を確定する
    if (_pendingChunks.isNotEmpty) {
      _sendPendingBatch();
    }
    var args = {
      "answerPort": answerPort.sendPort,
      "cmd": "terminate",
    };
    sendPort.send(args);
  }

  // 以降のキューの認識をスキップする
  void interrupt() {
    if (_isInterruptFlag) {
      return;
    }
    if (!_isInitializeFlag) {
      print("Warning : terminate : not initialized");
      return;
    }
    _isInterruptFlag = true;
    var args = {
      "cmd": "interrupt",
    };
    interruptPort.send(args);
  }

  void close() {
    if (!_isInitializeFlag) {
      print("Warning : close : not initialized");
      return;
    }
    isolate.kill();
    receivePort.close();
    answerPort.close();
    _isInitializeFlag = false;
  }
}

class AudioProcessingWhisperStreaming {
  final SpeechToTextIsolate _ailiaSpeechModel = SpeechToTextIsolate();

  Future<void> open(File onnx_encoder_file, File onnx_decoder_file, File vad_file, int env_id, String type, String lang, bool virtualMemory, bool liveTranscribe, Function intermediateCallback, Function messageCallback, Function finishCallback, {File? segmentationFile, File? embeddingFile}) async{
    int typeId = 0;
    if (type == "whisper_tiny"){
      typeId = ailia_speech_dart.AILIA_SPEECH_MODEL_TYPE_WHISPER_MULTILINGUAL_TINY;
    }
    if (type == "whisper_small"){
      typeId = ailia_speech_dart.AILIA_SPEECH_MODEL_TYPE_WHISPER_MULTILINGUAL_SMALL;
    }
    if (type == "whisper_medium"){
      // Please add com.apple.developer.kernel.increased-memory-limit for iOS
      typeId = ailia_speech_dart.AILIA_SPEECH_MODEL_TYPE_WHISPER_MULTILINGUAL_MEDIUM;
    }
    if (type == "whisper_large_v3_turbo"){
      // Please add com.apple.developer.kernel.increased-memory-limit for iOS
      typeId = ailia_speech_dart.AILIA_SPEECH_MODEL_TYPE_WHISPER_MULTILINGUAL_LARGE_V3;
    }
    if (type == "sensevoice_small"){
      typeId = ailia_speech_dart.AILIA_SPEECH_MODEL_TYPE_SENSEVOICE_SMALL;
    }
    if (virtualMemory){
      Directory path = await getTemporaryDirectory();
      AiliaModel.setTemporaryCachePath(path.path);
    }
    _ailiaSpeechModel.init(
      intermediateCallback,
      messageCallback,
      finishCallback,
      onnx_encoder_file,
      onnx_decoder_file,
      vad_file,
      typeId,
      liveTranscribe,
      lang,
      true,
      speechEngineEnvId(env_id),
      virtualMemory,
      segmentationFile,
      embeddingFile,
    );
  }

  void send(List<double> pcm, int samplesPerSecond){
    _ailiaSpeechModel.send(pcm, samplesPerSecond, 1);
  }

  void terminate(){
    _ailiaSpeechModel.terminate();
  }

  void close(){
    _ailiaSpeechModel.close();
  }

}
