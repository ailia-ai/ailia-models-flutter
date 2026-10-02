import 'dart:ffi';

import '../utils/qnn_device.dart';

import 'qnn_model.dart';

/// Only probe the native QNN plugin in a Windows ARM64 process.
String? availableWindowsQnnSoc() {
  if (Abi.current() != Abi.windowsArm64) return null;
  final soc = qnnSocName;
  return windowsQnnSocs.contains(soc) ? soc : null;
}
