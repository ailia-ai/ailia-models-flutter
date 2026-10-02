import 'dart:ffi';

import 'package:ailia_llm/ailia_llm_model.dart';

import 'qnn_model.dart';

/// Only probe the native QNN plugin in a Windows ARM64 process.
String? availableWindowsQnnSoc() {
  if (Abi.current() != Abi.windowsArm64) return null;
  try {
    final soc = AiliaLLMModel.getQNNModelName();
    return windowsQnnSocs.contains(soc) ? soc : null;
  } catch (_) {
    // A missing plugin, runtime or NPU driver leaves CPU/GPU usable.
    return null;
  }
}
