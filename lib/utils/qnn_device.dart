import 'dart:ffi';

import 'package:ailia_llm/ailia_llm_model.dart';

/// Probe once without limiting detection to SoCs with published LLM models.
/// SDK FP16 policy also needs SoCs that have no converted LLM context binary.
final String? qnnSocName = _detectQnnSoc();

String? _detectQnnSoc() {
  if (Abi.current() != Abi.windowsArm64 && Abi.current() != Abi.androidArm64) {
    return null;
  }
  try {
    final soc = AiliaLLMModel.getQNNModelName().trim().toLowerCase();
    return soc.isEmpty ? null : soc;
  } catch (_) {
    // Missing QNN runtime or unsupported device: retain existing behavior.
    return null;
  }
}
