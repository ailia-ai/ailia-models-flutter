// Helpers for running the speech models on QNN environments.

import 'package:ailia/ailia.dart'
    show
        AILIA_ENVIRONMENT_ID_AUTO,
        AILIA_ENVIRONMENT_TYPE_BLAS,
        AILIA_ENVIRONMENT_TYPE_CPU;
import 'package:ailia/ailia_model.dart';

/// Input length in seconds used to fix the graph input shape when
/// running on QNN, which cannot handle dynamic shapes.
const int qnnStaticInputLengthSec = 11;

/// Whether [envId] refers to a QNN environment, judged by the
/// environment name.
bool isQnnEnvironment(int envId) {
  if (envId < 0) {
    return false;
  }
  for (final env in AiliaModel.getEnvironmentList()) {
    if (env.id == envId) {
      return env.name.toUpperCase().contains('QNN');
    }
  }
  return false;
}

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
