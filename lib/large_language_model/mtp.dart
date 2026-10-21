import 'package:ailia_llm/ailia_llm_model.dart';

import 'qnn_model.dart';

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
