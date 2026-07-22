import 'package:flutter/material.dart';

import '../backend_state.dart';
import '../model_catalog.dart';
import 'demo/chat_demo_page.dart';
import 'demo/nlp_demo_page.dart';
import 'demo/stt_demo_page.dart';
import 'demo/tts_demo_page.dart';
import 'demo/vision_demo_page.dart';
import 'demo/vlm_demo_page.dart';

/// Entry point for a model demo: picks the page for the model's
/// category. Each page owns its input UI, inference glue and result
/// presentation, built on the shared pieces in demo/ (DemoSession,
/// CameraInput, the waveform and the common page scaffold).
class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key, required this.model});

  final ModelInfo model;

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  @override
  void initState() {
    super.initState();
    // Each demo starts on its default backend: QNN (HTP) for the
    // QNN-ready models, the CPU backend for everything else.
    BackendState.instance
        .applyModelDefault(preferQnn: widget.model.qnnSupported);
  }

  @override
  Widget build(BuildContext context) {
    final model = widget.model;
    if (model.isChat) {
      return ChatDemoPage(model: model);
    }
    if (model.input == ModelInputKind.imageText) {
      return VlmDemoPage(model: model);
    }
    if (model.isTextToSpeech) {
      return TtsDemoPage(model: model);
    }
    switch (model.input) {
      case ModelInputKind.image:
        return VisionDemoPage(model: model);
      case ModelInputKind.audio:
        return SttDemoPage(model: model);
      case ModelInputKind.text:
      case ModelInputKind.imageText:
        return NlpDemoPage(model: model);
    }
  }
}
