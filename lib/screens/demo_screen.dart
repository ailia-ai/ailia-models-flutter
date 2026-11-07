import 'package:flutter/material.dart';

import '../backend_state.dart';
import '../model_catalog.dart';
import 'demo/alm_demo_page.dart';
import 'demo/chat_demo_page.dart';
import 'demo/diffusion_demo_page.dart';
import 'demo/model_variant_selector.dart';
import 'demo/nlp_demo_page.dart';
import 'demo/stt_demo_page.dart';
import 'demo/tts_demo_page.dart';
import 'demo/tool_use_demo_page.dart';
import 'demo/vision_demo_page.dart';
import 'demo/voice_agent_demo_page.dart';
import 'demo/vlm_demo_page.dart';

/// Entry point for a model demo: picks the page for the model's
/// category. Each page owns its input UI, inference glue and result
/// presentation, built on the shared pieces in demo/ (DemoSession,
/// CameraInput, the waveform and the common page scaffold).
///
/// [model] is the variant opened first; when its card groups several
/// models the page scaffold offers a selector, and a change rebuilds the
/// page from scratch for the selected model.
class DemoScreen extends StatefulWidget {
  const DemoScreen({super.key, required this.model});

  final ModelInfo model;

  @override
  State<DemoScreen> createState() => _DemoScreenState();
}

class _DemoScreenState extends State<DemoScreen> {
  late ModelInfo _model = widget.model;
  late final List<ModelInfo> _variants = groupOf(widget.model).variants;

  @override
  void initState() {
    super.initState();
    _applyBackendDefault();
  }

  /// Each demo starts on its default backend: QNN (HTP) for the
  /// QNN-ready models, the CPU backend for everything else.
  void _applyBackendDefault() {
    BackendState.instance.applyModelDefault(
      preferQnn: _model.qnnSupported,
      forLlm: _model.usesLlmBackend,
      speechModel: _model.isSpeechToText ? _model.id : null,
      supportedQnnSocs: _model.supportedQnnSocs,
    );
  }

  void _select(ModelInfo model) {
    _model = model;
    _applyBackendDefault();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ModelVariantScope(
      variants: _variants,
      selected: _model,
      onSelected: _select,
      // A new key disposes the previous variant's page (and its models).
      child: KeyedSubtree(key: ValueKey(_model.id), child: _buildPage(_model)),
    );
  }

  Widget _buildPage(ModelInfo model) {
    if (model.category == 'Voice Agent') {
      return const VoiceAgentDemoPage();
    }
    if (model.category == 'Tool Use') {
      return ToolUseDemoPage(model: model);
    }

    if (model.isChat) {
      return ChatDemoPage(model: model);
    }
    if (model.category == 'Diffusion') {
      return DiffusionDemoPage(model: model);
    }
    if (model.category == 'ALM') {
      return AlmDemoPage(model: model);
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
