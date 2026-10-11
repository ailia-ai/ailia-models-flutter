import 'dart:async';

import 'package:flutter/material.dart';

import '../../backend_state.dart';
import '../../large_language_model/qnn_model.dart';

/// MTP pays off on the NPU; on CPU / GPU the extra draft and verification
/// work can make free-form generation slower, so it starts off there.
bool mtpDefaultFor(String llmBackend) => isLlmQnnBackend(llmBackend);

/// Holds the page's MTP toggle, defaulting to on for the NPU (QNN) and
/// off otherwise, and resetting to that default when the backend changes.
mixin MtpToggleMixin<T extends StatefulWidget> on State<T> {
  ValueNotifier<String> get _llmBackend =>
      BackendState.instance.selectedLlmBackend;

  late bool mtp = mtpDefaultFor(_llmBackend.value);

  @override
  void initState() {
    super.initState();
    _llmBackend.addListener(_onBackendChanged);
  }

  void _onBackendChanged() {
    // The backend list may update the selection while a frame is built.
    scheduleMicrotask(() {
      final value = mtpDefaultFor(_llmBackend.value);
      if (mounted && value != mtp) setState(() => mtp = value);
    });
  }

  @override
  void dispose() {
    _llmBackend.removeListener(_onBackendChanged);
    super.dispose();
  }
}

/// Toggle for MTP (Multi-Token Prediction). The assistant cannot be
/// detached from an opened model, so pages reopen the model when the
/// value changes.
class MtpSwitch extends StatelessWidget {
  const MtpSwitch({super.key, required this.value, required this.onChanged});

  final bool value;

  /// Null disables the switch (e.g. while generating).
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Multi-Token Prediction: a draft model proposes '
          '$mtpDraftTokens tokens and the main model verifies them at once',
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('MTP'),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}
