import 'package:ailia/ailia.dart'
    show AILIA_ENVIRONMENT_TYPE_BLAS, AILIA_ENVIRONMENT_TYPE_CPU;
import 'package:ailia/ailia_model.dart';
import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:flutter/material.dart';

/// Holds the backend selections shared by every screen. The selection
/// lives in the top bar on both the home screen and the demo screens.
///
/// ailia LLM uses its own backend list (CPU/Vulkan/OpenCL/Metal from
/// llama.cpp) which is different from the ailia SDK environment list,
/// so the two selections are kept separately.
class BackendState {
  BackendState._();
  static final BackendState instance = BackendState._();

  List<AiliaEnvironment> _envList = [];
  final ValueNotifier<int> selectedEnvId = ValueNotifier<int>(0);

  List<String> _llmBackendList = [];
  final ValueNotifier<String> selectedLlmBackend = ValueNotifier<String>('');

  /// The BLAS-accelerated CPU backend (CPU-AppleAccelerate on macOS,
  /// CPU-IntelMKL on Windows, CPU-OpenBlas on Android, ...).
  static bool _isBlas(AiliaEnvironment e) =>
      e.type == AILIA_ENVIRONMENT_TYPE_BLAS;

  static bool _isCpu(AiliaEnvironment e) =>
      e.type == AILIA_ENVIRONMENT_TYPE_CPU;

  /// QNN provides CPU / GPU / HTP variants, but only HTP (the NPU) is
  /// meaningful for the demos; hide the QNN CPU and GPU variants from
  /// the selector.
  static bool _isSelectable(AiliaEnvironment e) {
    final name = e.name.toUpperCase();
    return !(name.contains('QNN') &&
        (name.contains('CPU') || name.contains('GPU')));
  }

  List<AiliaEnvironment> get envList {
    if (_envList.isEmpty) {
      _envList =
          AiliaModel.getEnvironmentList().where(_isSelectable).toList();
      if (_envList.isNotEmpty) {
        // Default to the BLAS backend when available; it is much faster
        // than the plain CPU environment. The QNN build has no BLAS, so
        // fall back to the plain CPU environment rather than QNN-HTP.
        selectedEnvId.value = _envList
            .firstWhere(_isBlas,
                orElse: () => _envList.firstWhere(_isCpu,
                    orElse: () => _envList.first))
            .id;
      }
    }
    return _envList;
  }

  AiliaEnvironment get selectedEnv => envList.firstWhere(
        (e) => e.id == selectedEnvId.value,
        orElse: () => envList.first,
      );

  /// Applies the default backend when a demo opens: the QNN (HTP)
  /// environment for QNN-ready models when present, otherwise the CPU
  /// backend (BLAS preferred). The user can still change the backend
  /// from the top bar afterwards.
  void applyModelDefault({required bool preferQnn}) {
    final list = envList;
    if (list.isEmpty) {
      return;
    }
    AiliaEnvironment? pick;
    if (preferQnn) {
      for (final env in list) {
        if (env.name.toUpperCase().contains('QNN')) {
          pick = env;
          break;
        }
      }
    }
    pick ??= list.firstWhere(_isBlas,
        orElse: () => list.firstWhere(_isCpu, orElse: () => list.first));
    selectedEnvId.value = pick.id;
  }

  List<String> get llmBackendList {
    if (_llmBackendList.isEmpty) {
      _llmBackendList = AiliaLLMModel.getBackendList();
      if (_llmBackendList.isNotEmpty &&
          !_llmBackendList.contains(selectedLlmBackend.value)) {
        selectedLlmBackend.value = _llmBackendList.first;
      }
    }
    return _llmBackendList;
  }
}

/// Backend dropdown for the AppBar. Shown on every screen so that the
/// backend can be chosen consistently from the top bar.
///
/// When [forLlm] is true the selector lists the ailia LLM backends
/// instead of the ailia SDK environments.
class BackendSelector extends StatelessWidget {
  const BackendSelector({super.key, this.forLlm = false});

  final bool forLlm;

  @override
  Widget build(BuildContext context) {
    final onColor = Theme.of(context).colorScheme.onSurface;
    return Padding(
      padding: const EdgeInsets.only(right: 16.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.memory, size: 20, color: onColor),
          const SizedBox(width: 8),
          forLlm ? _buildLlmSelector() : _buildEnvSelector(),
        ],
      ),
    );
  }

  Widget _buildEnvSelector() {
    final state = BackendState.instance;
    final envList = state.envList;
    if (envList.isEmpty) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<int>(
      valueListenable: state.selectedEnvId,
      builder: (context, envId, _) {
        return DropdownButton<int>(
          value: envList.any((e) => e.id == envId) ? envId : envList.first.id,
          underline: const SizedBox.shrink(),
          items: envList
              .map((env) => DropdownMenuItem<int>(
                    value: env.id,
                    child: Text(env.name),
                  ))
              .toList(),
          onChanged: (value) {
            if (value != null) {
              state.selectedEnvId.value = value;
            }
          },
        );
      },
    );
  }

  Widget _buildLlmSelector() {
    final state = BackendState.instance;
    final backendList = state.llmBackendList;
    if (backendList.isEmpty) {
      return const SizedBox.shrink();
    }
    return ValueListenableBuilder<String>(
      valueListenable: state.selectedLlmBackend,
      builder: (context, backend, _) {
        return DropdownButton<String>(
          value: backendList.contains(backend) ? backend : backendList.first,
          underline: const SizedBox.shrink(),
          items: backendList
              .map((name) => DropdownMenuItem<String>(
                    value: name,
                    child: Text(name),
                  ))
              .toList(),
          onChanged: (value) {
            if (value != null) {
              state.selectedLlmBackend.value = value;
            }
          },
        );
      },
    );
  }
}
