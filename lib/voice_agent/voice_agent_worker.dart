import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:ailia_speech/ailia_speech.dart' as speech_api;
import 'package:ailia_speech/ailia_speech_model.dart';
import 'package:ailia_voice/ailia_voice.dart' as voice_api;
import 'package:ailia_voice/ailia_voice_model.dart';
import 'package:ffi/ffi.dart';

import '../large_language_model/qnn_model.dart';
import '../text_to_speech/text_to_speech.dart';
import 'voice_agent_config.dart';
import 'voice_agent_conversation.dart';
import 'voice_agent_speech_turn.dart';

/// Small RPC client. Cancellation interrupts between native calls; shutdown
/// joins the isolate after its owning thread has released every native handle.
class VoiceAgentWorker {
  ReceivePort? _events;
  SendPort? _commands;
  final _pending = <int, Completer<dynamic>>{};
  final _exited = Completer<void>();
  int _sequence = 0;
  bool _closing = false;
  bool _started = false;
  void Function(Map<String, dynamic>)? onEvent;
  Future<String> Function()? takePhoto;

  Future<void> start() async {
    if (_started || _closing) {
      throw StateError('Voice Agent worker already started');
    }
    _started = true;
    final events = ReceivePort();
    _events = events;
    final ready = Completer<void>();
    events.listen((dynamic message) async {
      if (message is SendPort) {
        _commands = message;
        if (_closing) message.send({'method': 'close'});
        ready.complete();
      } else if (message == null || message is List) {
        _commands = null;
        final error = StateError('Voice Agent worker exited: $message');
        if (!ready.isCompleted) ready.completeError(error);
        for (final pending in _pending.values) {
          pending.completeError(error);
        }
        _pending.clear();
        events.close();
        if (!_exited.isCompleted) _exited.complete();
      } else {
        final event = Map<String, dynamic>.from(message as Map);
        if (event.containsKey('id')) {
          final pending = _pending.remove(event['id']);
          if (event['cancelled'] == true) {
            pending?.completeError(const VoiceAgentCancelled());
          } else if (event.containsKey('error')) {
            pending?.completeError(StateError(event['error'] as String));
          } else {
            pending?.complete(event['result']);
          }
        } else if (event['type'] == 'photo') {
          final reply = event['reply'] as SendPort;
          try {
            if (_closing || takePhoto == null) {
              throw const VoiceAgentCancelled();
            }
            reply.send({'data': await takePhoto!()});
          } catch (error) {
            reply.send({'error': '$error'});
          }
        } else if (!_closing) {
          onEvent?.call(event);
        }
      }
    });
    try {
      await Isolate.spawn(
        _runVoiceAgentWorker,
        events.sendPort,
        onError: events.sendPort,
        onExit: events.sendPort,
      );
    } catch (error) {
      events.close();
      _events = null;
      if (!_exited.isCompleted) _exited.complete();
      rethrow;
    }
    await ready.future;
  }

  Future<dynamic> call(String method, [Map<String, dynamic> args = const {}]) {
    if (_closing || _commands == null || _exited.isCompleted) {
      throw StateError('Voice Agent worker is unavailable');
    }
    final id = ++_sequence;
    final pending = Completer<dynamic>();
    _pending[id] = pending;
    _commands!.send({'id': id, 'method': method, ...args});
    return pending.future;
  }

  void cancel() => _commands?.send({'method': 'cancel'});

  Future<void> close() async {
    if (_closing) return _exited.future;
    _closing = true;
    if (_events == null) {
      if (!_exited.isCompleted) _exited.complete();
    } else {
      _commands?.send({'method': 'close'});
    }
    await _exited.future;
  }
}

class _SpeechEngine implements VoiceAgentSpeechEngine {
  _SpeechEngine(this.model);
  final AiliaSpeechModel model;
  @override
  void push(List<double> audio, int rate, int channels) =>
      model.pushInputData(audio, rate, channels);
  @override
  bool get buffered => model.isBuffered();
  @override
  void finalize() => model.finalizeInputData();
  @override
  List<String> transcribe() =>
      model.transcribe().map((t) => t.text as String).toList();
  @override
  bool get complete => model.isComplete();
  @override
  void reset() => model.reset();
}

/// These two queries are exposed in the SDK's generated bindings, but not yet
/// in AiliaLLMModel. Keep the binding access local to the model owner.
class _VoiceLlm extends AiliaLLMModel {
  int _query(bool context) {
    final value = calloc<UnsignedInt>();
    try {
      final status = context
          ? dllHandle.ailiaLLMGetContextSize(pLLm.value, value)
          : dllHandle.ailiaLLMGetPromptTokenCount(pLLm.value, value);
      if (status != 0) {
        throw StateError('LLM token count query failed: $status');
      }
      return value.value;
    } finally {
      calloc.free(value);
    }
  }

  int get contextSize => _query(true);
  int get promptTokens => _query(false);
}

void _runVoiceAgentWorker(SendPort events) {
  final commands = ReceivePort();
  events.send(commands.sendPort);
  AiliaSpeechModel? speech;
  VoiceAgentSpeechTurn? speechTurn;
  _VoiceLlm? llm;
  AiliaVoiceModel? voice;
  final conversation = VoiceAgentConversation();
  var cancelled = false;
  var closing = false;
  Completer<void>? photoCancelled;
  var queue = Future<void>.value();

  void check() {
    if (cancelled || closing) throw const VoiceAgentCancelled();
  }

  void closeSpeech() {
    speechTurn = null;
    final model = speech;
    speech = null;
    model?.close();
  }

  void closeVoice() {
    final model = voice;
    voice = null;
    model?.close();
  }

  Future<dynamic> execute(Map command) async {
    switch (command['method']) {
      case 'listen':
        cancelled = false;
        check();
        closeSpeech();
        final model = AiliaSpeechModel();
        speech = model;
        model.create(false, false, command['env'] as int);
        final files = (command['files'] as List).cast<String>();
        model.open(
          File(files[1]),
          File(files.length > 2 ? files[2] : files[1]),
          File(files[0]),
          'ja',
          command['model'] == 'whisper_medium'
              ? speech_api.AILIA_SPEECH_MODEL_TYPE_WHISPER_MULTILINGUAL_MEDIUM
              : speech_api
                    .AILIA_SPEECH_MODEL_TYPE_WHISPER_MULTILINGUAL_LARGE_V3,
        );
        // Match the Kotlin agent's quiet-speech policy, without an RMS gate.
        final status = model.ailiaSpeech.ailiaSpeechSetSilentThreshold(
          model.ppAilia!.value,
          0.5,
          0.25,
          1.0,
        );
        model.throwError('ailiaSpeechSetSilentThreshold', status as int);
        model.setIntermediateCallback(
          (text) => events.send({'type': 'input', 'text': text}),
        );
        speechTurn = VoiceAgentSpeechTurn(_SpeechEngine(model));
        return null;
      case 'push':
        check();
        return speechTurn!.push(
          (command['pcm'] as List).cast<double>(),
          command['rate'] as int,
          channels: command['channels'] as int? ?? 1,
        );
      case 'recognize':
        check();
        try {
          return speechTurn!.finish(check).join('\n').trim();
        } finally {
          closeSpeech();
        }
      case 'discard':
        closeSpeech();
        return null;
      case 'reply':
        cancelled = false;
        check();
        closeSpeech();
        final model = _VoiceLlm();
        llm = model;
        try {
          final backend = command['backend'] as String;
          final path = command['body'] as String;
          model.open(
            path,
            isLlmQnnBackend(backend) ? 0 : 4096,
            backend: backend,
          );
          check();
          final mtp = command['mtp'] as String?;
          if (mtp != null) model.openMtpModel(mtp, mtpDraftTokens);
          model.openMultimodalProjectorFile(command['projector'] as String);
          check();
          return await conversation.reply(
            model,
            command['input'] as String,
            contextSize: model.contextSize,
            promptTokens: () => model.promptTokens,
            checkActive: check,
            emit: events.send,
            takePhoto: () async {
              final response = ReceivePort();
              final interrupted = Completer<void>();
              photoCancelled = interrupted;
              events.send({'type': 'photo', 'reply': response.sendPort});
              try {
                final value = await Future.any<dynamic>([
                  response.first,
                  interrupted.future.then(
                    (_) => throw const VoiceAgentCancelled(),
                  ),
                ]);
                check();
                if (value['error'] != null) {
                  throw StateError(value['error'] as String);
                }
                return value['data'] as String;
              } finally {
                photoCancelled = null;
                response.close();
              }
            },
          );
        } finally {
          llm = null;
          model.close();
        }
      case 'voiceOpen':
        cancelled = false;
        check();
        closeVoice();
        final model = AiliaVoiceModel();
        voice = model;
        final root = command['root'] as String;
        const distill = 'gpt-sovits-v2-pro-distill';
        const base = 'gpt-sovits-v2-pro';
        model.openGPTSoVITSV2ProModel(
          '$root/$distill/t2s_encoder_distill_base.onnx',
          '$root/$distill/t2s_fsdec_distill_base.onnx',
          '$root/$distill/t2s_sdec_distill_base.opt.onnx',
          '$root/$base/cnhubert.onnx',
          '$root/$distill/vits_distill_base.onnx',
          '$root/$base/sv.onnx',
          null,
          null,
          command['env'] as int,
        );
        model.openDictionary(
          '$root/open_jtalk_dic_utf_8-1.11/',
          voice_api.AILIA_VOICE_DICTIONARY_TYPE_OPEN_JTALK,
        );
        model.openDictionary(
          '$root/',
          voice_api.AILIA_VOICE_DICTIONARY_TYPE_G2P_EN,
        );
        final reference = model.g2p(
          '水をマレーシアから買わなくてはならない。',
          voice_api.AILIA_VOICE_G2P_TYPE_GPT_SOVITS_JA,
        );
        model.setReference(
          (command['reference'] as List).cast<double>(),
          command['rate'] as int,
          command['channels'] as int,
          reference,
        );
        return null;
      case 'synthesize':
        check();
        final text = command['text'] as String;
        final feature = voice!.g2p(
          text,
          TextToSpeech.isEnglishText(text)
              ? voice_api.AILIA_VOICE_G2P_TYPE_GPT_SOVITS_EN
              : voice_api.AILIA_VOICE_G2P_TYPE_GPT_SOVITS_JA,
        );
        final audio = voice!.inference(feature);
        check();
        return {
          'pcm': Float64List.fromList(audio.pcm),
          'rate': audio.sampleRate,
          'channels': audio.nChannels,
        };
      case 'voiceRelease':
        closeVoice();
        return null;
      default:
        throw StateError('Unknown voice agent command: ${command['method']}');
    }
  }

  commands.listen((dynamic value) {
    final command = value as Map;
    if (command['method'] == 'cancel' || command['method'] == 'close') {
      cancelled = true;
      photoCancelled?.complete();
      photoCancelled = null;
      if (command['method'] == 'close') {
        closing = true;
        queue = queue.then((_) {
          try {
            closeSpeech();
          } finally {
            try {
              llm?.close();
            } finally {
              try {
                closeVoice();
              } finally {
                commands.close();
              }
            }
          }
        });
      }
      return;
    }
    queue = queue.then((_) async {
      try {
        if (closing) throw const VoiceAgentCancelled();
        final result = await execute(command);
        events.send({'id': command['id'], 'result': result});
      } on VoiceAgentCancelled {
        events.send({'id': command['id'], 'cancelled': true});
      } catch (error) {
        events.send({'id': command['id'], 'error': '$error'});
      }
    });
  });
}
