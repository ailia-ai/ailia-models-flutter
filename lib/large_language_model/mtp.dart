import 'package:ailia_llm/ailia_llm_model.dart';

/// Opens the MTP assistant right after the body (before the projector and
/// the first prompt). Returns null on success, otherwise the error. On
/// failure MTP stays disabled and the body keeps generating one token per
/// step, so callers report the error instead of failing the demo.
String? openMtpAssistant(AiliaLLMModel model, String? assistantPath) {
  if (assistantPath == null || assistantPath.isEmpty) return null;
  try {
    model.openMtpModel(assistantPath, mtpDraftTokens);
    return null;
  } catch (error) {
    return '$error';
  }
}

/// One-line MTP state for the result panel.
String mtpStatusText({required bool requested, String? error}) {
  if (!requested) return 'MTP: off';
  if (error != null) return 'MTP: unavailable ($error)';
  return 'MTP: on (n_draft=$mtpDraftTokens)';
}

/// Number of draft tokens the MTP assistant proposes per verification.
const mtpDraftTokens = 3;

/// Gemma 4 models with a published MTP assistant (draft model).
bool supportsMtp(String type) =>
    type == 'gemma4-e2b' ||
    type == 'gemma4-e4b' ||
    type == 'gemma4-e2b-vlm' ||
    type == 'gemma4-e2b-alm' ||
    type == 'gemma4-e2b-tool-use';

/// [folder, file] of the GGUF MTP assistant matching the model.
List<String> mtpAssistantFiles(String type) {
  final model = switch (type) {
    'gemma4-e4b' => 'E4B',
    _ when supportsMtp(type) => 'E2B',
    _ => throw UnsupportedError('No MTP assistant for $type'),
  };
  return ['gemma', 'mtp-gemma-4-$model-it-Q4_0.gguf'];
}
