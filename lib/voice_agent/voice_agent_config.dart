import '../large_language_model/qnn_model.dart';

enum VoiceAgentState {
  preparing('モデルを準備しています'),
  listening('音声入力を待っています'),
  synthesizingQuery('テストクエリの音声を合成しています'),
  waitingQuery('次のテスト音声を待っています'),
  playingQuery('テストクエリの音声を再生しています'),
  submitting('音声を送信しています'),
  recognizing('音声を認識しています'),
  thinking('応答を考えています'),
  synthesizing('音声を合成しています'),
  speaking('応答を読み上げています'),
  cancelling('応答を中止しています'),
  testComplete('テスト完了'),
  stopping('対話を終了しています');

  const VoiceAgentState(this.label);
  final String label;

  bool get interruptible => switch (this) {
    synthesizingQuery ||
    waitingQuery ||
    playingQuery ||
    submitting ||
    recognizing ||
    thinking ||
    synthesizing ||
    speaking ||
    testComplete => true,
    _ => false,
  };
}

class VoiceAgentConfig {
  const VoiceAgentConfig({
    this.speechModel = 'whisper_medium',
    this.llmModel = 'gemma4-e2b',
    required this.speechEnvId,
    required this.voiceEnvId,
    required this.llmBackend,
    bool? mtp,
    this.speechOutput = true,
    this.testMode = false,
    this.queries = const [],
    this.frontCamera = false,
    this.cameraDeviceId,
  }) : mtp = mtp ?? llmModel == 'gemma4-e2b';

  static const defaultQueries = '自己紹介をしてください。\n一足す一はいくつですか。';
  final String speechModel;
  final String llmModel;
  final int speechEnvId;
  final int voiceEnvId;
  final String llmBackend;
  final bool mtp;
  final bool speechOutput;
  final bool testMode;
  final List<String> queries;
  final bool frontCamera;

  /// An explicit device takes precedence over the mobile front/rear choice.
  final String? cameraDeviceId;

  bool get needsVoice => speechOutput || testMode;

  void validate() {
    if (!{'whisper_medium', 'whisper_large_v3_turbo'}.contains(speechModel) ||
        !{'gemma4-e2b', 'gemma4-e4b'}.contains(llmModel)) {
      throw ArgumentError(
        'Whisper Medium / Turbo と Gemma 4 E2B / E4B を選択してください',
      );
    }
    if (testMode && (queries.isEmpty || queries.any((q) => q.trim().isEmpty))) {
      throw ArgumentError('テストクエリを1行に1件ずつ入力してください');
    }
  }

  /// Body, matching projector, then optional MTP assistant; folder/file pairs.
  List<String> llmFiles({String? soc}) {
    validate();
    final qnn = isLlmQnnBackend(llmBackend);
    final size = llmModel == 'gemma4-e4b' ? 'E4B' : 'E2B';
    final body = qnn
        ? qnnTextModelFiles(llmModel, soc ?? '')
        : ['gemma', 'gemma-4-$size-it-Q4_K_M.gguf'];
    final projector = qnn
        ? llmModel == 'gemma4-e2b'
              ? qnnMmprojFiles(soc ?? '')
              : [
                  qnnModelFormat == QnnModelFormat.v150
                      ? qnnLegacyModelFolder
                      : qnnModelFolder,
                  qnnModelFormat == QnnModelFormat.v150
                      ? '$llmModel-$soc-mmproj.qnn'
                      : '$llmModel-$soc-${qnnPrecision(soc!)}-mmproj.qnn',
                ]
        : ['gemma', 'gemma-4-$size-it-mmproj-F16.gguf'];
    return [
      ...body,
      ...projector,
      if (mtp && mtpAvailable(llmModel, llmBackend))
        ...mtpAssistantFiles(llmModel, llmBackend, soc: soc),
    ];
  }
}

class VoiceAgentCancelled implements Exception {
  const VoiceAgentCancelled();
}
