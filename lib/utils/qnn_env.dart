// Helpers for running the speech models on QNN. ailia Speech opens its
// own .qnn context binaries like ailia LLM, so QNN is offered only on
// SoCs with a published package, independently of the ailia SDK QNN
// environments.

import 'dart:ffi';

import 'package:ailia/ailia.dart'
    show
        AILIA_ENVIRONMENT_ID_AUTO,
        AILIA_ENVIRONMENT_TYPE_BLAS,
        AILIA_ENVIRONMENT_TYPE_CPU;
import 'package:ailia/ailia_model.dart';

import 'qnn_device.dart';

/// ailia Speech 1.6.0 Whisper context binaries. Opening the .qnn as the
/// model is enough to run it on QNN (HTP); the encoder and the decoder
/// are packed into the same file.
const speechQnnModelFolder = 'whisper/qnn/v1.6.0';

/// SoCs with a published Whisper context binary. Every model below is
/// published for the same SoCs.
const speechQnnSocs = {'qcs6490', 'sc8380xp', 'sm7635', 'sm8475'};

const _speechQnnModelNames = {
  'whisper_medium': 'whisper-medium',
  'whisper_large_v3_turbo': 'whisper-large-v3-turbo',
};

/// [folder, file] of the Whisper context binary of [type] for [soc].
/// Never substitute a different SoC's package.
List<String> speechQnnModelFiles(String type, String soc) {
  final name = _speechQnnModelNames[type];
  if (name == null || !speechQnnSocs.contains(soc)) {
    throw UnsupportedError(
        'No QNN context binary of $type for SoC "$soc". QNN supports '
        'Whisper Medium / Large V3 Turbo on ${speechQnnSocs.join(' / ')}.');
  }
  return [speechQnnModelFolder, '$name-$soc-int16.qnn'];
}

/// Pseudo environment id of the ailia Speech QNN (HTP) backend in the
/// backend selector. It never collides with ailia SDK environment ids.
const speechQnnEnvId = -100;

/// Selector entry for [speechQnnEnvId].
final AiliaEnvironment speechQnnEnvironment = AiliaEnvironment()
  ..id = speechQnnEnvId
  ..name = 'HTP (QNN)';

/// The SoC to open the Whisper context binary of [type] for, or null
/// when this device has none. ailia Speech runs .qnn on Windows ARM64.
String? speechQnnSoc(String type) {
  if (Abi.current() != Abi.windowsArm64) return null;
  final soc = qnnSocName;
  return _speechQnnModelNames.containsKey(type) && speechQnnSocs.contains(soc)
      ? soc
      : null;
}

/// Environment to create the ailia Speech instance on. The .qnn context
/// binary runs on QNN by itself, so the instance (and the VAD) stays on
/// the CPU when the QNN backend is selected.
int speechEngineEnvId(int envId) =>
    envId == speechQnnEnvId ? cpuEnvironmentId() : envId;

/// The BLAS environment when available, otherwise the plain CPU
/// environment. Used for the model components that cannot run on QNN.
int cpuEnvironmentId() {
  final envList = AiliaModel.getEnvironmentList();
  for (final env in envList) {
    if (env.type == AILIA_ENVIRONMENT_TYPE_BLAS) {
      return env.id;
    }
  }
  for (final env in envList) {
    if (env.type == AILIA_ENVIRONMENT_TYPE_CPU) {
      return env.id;
    }
  }
  return AILIA_ENVIRONMENT_ID_AUTO;
}
