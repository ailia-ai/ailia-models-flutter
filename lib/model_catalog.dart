import 'package:flutter/material.dart';

import 'large_language_model/qnn_model.dart';
import 'utils/qnn_device.dart';
import 'utils/qnn_env.dart';
import 'utils/qnn_support.dart';

/// What kind of input the demo consumes. Used to decide which input
/// source toggle (image/webcam or audio/mic) is shown on the demo screen.
enum ModelInputKind { image, audio, text, imageText }

class ModelInfo {
  final String id;
  final String name;
  final String category;
  final ModelInputKind input;

  /// Bundled sample image shown before the first run (image demos).
  final String? sampleAsset;

  /// Initial text for the demo's text input box (TTS text, translation
  /// source, ...).
  final String? defaultInputText;

  /// Whether the model runs on the QNN (HTP) backend. QNN-ready models
  /// show a QNN badge on the home screen and default to the QNN
  /// backend when their demo opens.
  final bool qnnSupported;
  final Set<String>? supportedQnnSocs;

  /// Card name shared by the variants of one model family. Consecutive
  /// catalog entries with the same group and category are shown as one
  /// card on the home screen, and the demo screen offers a selector
  /// between them.
  final String? group;

  /// The variant a grouped card opens with.
  final bool groupDefault;

  const ModelInfo(this.id, this.name, this.category, this.input,
      {this.sampleAsset,
      this.defaultInputText,
      this.qnnSupported = false,
      this.supportedQnnSocs,
      this.group,
      this.groupDefault = false});

  bool get isSpeechToText => category == 'Speech To Text';
  bool get isTextToSpeech => category == 'Text To Speech';
  bool get usesLlmBackend =>
      category == 'Large Language Model' ||
      category == 'VLM' ||
      category == 'ALM' ||
      category == 'Tool Use' ||
      category == 'Voice Agent';

  /// Text-only LLMs get the multi-turn chat UI.
  bool get isChat =>
      category == 'Large Language Model' && input == ModelInputKind.text;

  /// Whether the QNN (NPU) backend is available for this model on this
  /// device. ailia Speech needs a context binary for this SoC; the other
  /// models follow [showQnnMark].
  bool get qnnAvailable => isSpeechToText
      ? qnnSupported && speechQnnSoc(id) != null
      : showQnnMark(
          qnnSupported: qnnSupported,
          usesLlmBackend: usesLlmBackend,
          soc: qnnSocName,
          supportedQnnSocs: supportedQnnSocs,
        );

  /// Name shown in the model selector, marking QNN-ready variants.
  String get selectorLabel => qnnAvailable ? '$name [QNN]' : name;
}

// Card names of the model families shown as one card (see ModelGroup).
const _samGroup = 'Segment Anything 2 / 3.1';
const _whisperGroup = 'Whisper';
const _fugumtGroup = 'FuguMT';
const _gptSovitsGroup = 'GPT-SoVITS';
const _llmGroup = 'Gemma 2 / 4';
const _vlmGroup = 'Gemma 3 / 4';
// Single-model cards that only need the family name (ALM, Tool Use).
const _gemma4Card = 'Gemma 4';

const List<ModelInfo> modelCatalog = [
  ModelInfo(
      'resnet50', 'ResNet50', 'Image Classification', ModelInputKind.image,
      sampleAsset: 'assets/clock.jpg', qnnSupported: true),
  ModelInfo('vit', 'ViT-B/16', 'Image Classification', ModelInputKind.image,
      sampleAsset: 'assets/clock.jpg', qnnSupported: true),
  ModelInfo(
      'sam2', 'Segment Anything 2', 'Image Segmentation', ModelInputKind.image,
      sampleAsset: 'assets/truck.jpg',
      group: _samGroup),
  ModelInfo('sam3.1', 'Segment Anything 3.1', 'Image Segmentation',
      ModelInputKind.image,
      sampleAsset: 'assets/truck.jpg', defaultInputText: 'truck',
      group: _samGroup, groupDefault: true),
  ModelInfo('u2net', 'U-2-Net', 'Background Removal', ModelInputKind.image,
      sampleAsset: 'assets/input_u2net.png', qnnSupported: true),
  ModelInfo('yolox', 'YOLOX-S', 'Object Detection', ModelInputKind.image,
      sampleAsset: 'assets/clock.jpg', qnnSupported: true),
  ModelInfo('detic', 'Detic', 'Object Detection', ModelInputKind.image,
      sampleAsset: 'assets/desk.jpg'),
  ModelInfo('bytetrack', 'ByteTrack', 'Object Tracking', ModelInputKind.image,
      sampleAsset: 'assets/clock.jpg', qnnSupported: true),
  ModelInfo('lw-human-pose', 'Lightweight Human Pose', 'Pose Estimation',
      ModelInputKind.image,
      sampleAsset: 'assets/person.jpg', qnnSupported: true),
  ModelInfo(
      'sdxl', 'Stable Diffusion XL', 'Diffusion', ModelInputKind.imageText,
      sampleAsset: 'assets/astronaut.jpg',
      defaultInputText:
          'Astronaut in a jungle, cold color palette, muted colors, detailed, 8k'),
  ModelInfo(
      'whisper_tiny', 'Whisper Tiny', 'Speech To Text', ModelInputKind.audio,
      group: _whisperGroup),
  ModelInfo(
      'whisper_small', 'Whisper Small', 'Speech To Text', ModelInputKind.audio,
      group: _whisperGroup),
  ModelInfo('whisper_medium', 'Whisper Medium', 'Speech To Text',
      ModelInputKind.audio,
      qnnSupported: true, supportedQnnSocs: speechQnnSocs,
      group: _whisperGroup),
  ModelInfo('whisper_large_v3_turbo', 'Whisper Large V3 Turbo',
      'Speech To Text', ModelInputKind.audio,
      qnnSupported: true, supportedQnnSocs: speechQnnSocs,
      group: _whisperGroup, groupDefault: true),
  ModelInfo('sensevoice_small', 'SenseVoice Small', 'Speech To Text',
      ModelInputKind.audio),
  ModelInfo('multilingual-e5', 'Multilingual-E5', 'Natural Language Processing',
      ModelInputKind.text),
  ModelInfo('fugumt-en-ja', 'FuguMT EN-JA', 'Natural Language Processing',
      ModelInputKind.text,
      defaultInputText: 'Hello world.',
      group: _fugumtGroup),
  ModelInfo('fugumt-ja-en', 'FuguMT JA-EN', 'Natural Language Processing',
      ModelInputKind.text,
      defaultInputText: 'こんにちは世界。',
      group: _fugumtGroup),
  ModelInfo('tacotron2', 'Tacotron2', 'Text To Speech', ModelInputKind.text,
      defaultInputText: 'Hello world.'),
  ModelInfo(
      'gpt-sovits-ja', 'GPT-SoVITS JA', 'Text To Speech', ModelInputKind.text,
      defaultInputText: 'こんにちは。今日はいい天気ですね。',
      group: _gptSovitsGroup),
  ModelInfo(
      'gpt-sovits-en', 'GPT-SoVITS EN', 'Text To Speech', ModelInputKind.text,
      defaultInputText: 'Hello world.',
      group: _gptSovitsGroup),
  ModelInfo(
      'gpt-sovits-zh', 'GPT-SoVITS ZH', 'Text To Speech', ModelInputKind.text,
      defaultInputText: '你好世界。',
      group: _gptSovitsGroup),
  ModelInfo('gpt-sovits-v2pro-ja', 'GPT-SoVITS V2Pro JA/EN', 'Text To Speech',
      ModelInputKind.text,
      defaultInputText: 'こんにちは。今日はいい天気ですね。',
      group: _gptSovitsGroup, groupDefault: true),
  ModelInfo(
      'gemma2', 'Gemma 2 2B', 'Large Language Model', ModelInputKind.text,
      group: _llmGroup),
  ModelInfo(
      'gemma4-e2b', 'Gemma 4 E2B', 'Large Language Model', ModelInputKind.text,
      qnnSupported: true,
      group: _llmGroup, groupDefault: true),
  ModelInfo(
      'gemma4-e4b', 'Gemma 4 E4B', 'Large Language Model', ModelInputKind.text,
      qnnSupported: true, supportedQnnSocs: {'sc8380xp'},
      group: _llmGroup),
  ModelInfo(
      'gemma3-multimodal', 'Gemma 3 4B VLM', 'VLM', ModelInputKind.imageText,
      group: _vlmGroup),
  ModelInfo(
      'gemma4-e2b-vlm', 'Gemma 4 E2B VLM', 'VLM', ModelInputKind.imageText,
      qnnSupported: true,
      group: _vlmGroup, groupDefault: true),
  ModelInfo('gemma4-e2b-alm', 'Gemma 4 E2B ALM', 'ALM', ModelInputKind.audio,
      qnnSupported: true, group: _gemma4Card),
  ModelInfo('gemma4-e2b-tool-use', 'Gemma 4 E2B Tool Use', 'Tool Use',
      ModelInputKind.text,
      defaultInputText: 'エアコンの温度を20度にしてください',
      qnnSupported: true,
      supportedQnnSocs: windowsQnnSocs,
      group: _gemma4Card),
  ModelInfo('voice-agent', 'Voice Agent', 'Voice Agent', ModelInputKind.audio,
      qnnSupported: true),
];

/// One home screen card: a single model, or the variants of a model
/// family sharing [ModelInfo.group], selectable inside the demo.
class ModelGroup {
  const ModelGroup(this.variants);

  final List<ModelInfo> variants;

  ModelInfo get first => variants.first;

  /// The variant the card opens with.
  ModelInfo get initial =>
      variants.firstWhere((m) => m.groupDefault, orElse: () => first);

  String get name => first.group ?? first.name;
  String get category => first.category;

  /// Whether any variant runs on the QNN (NPU) backend on this device.
  bool get qnnAvailable => variants.any((m) => m.qnnAvailable);
}

/// [modelCatalog] grouped into home screen cards, in catalog order.
final List<ModelGroup> modelGroups = () {
  final groups = <ModelGroup>[];
  for (final model in modelCatalog) {
    final last = groups.lastOrNull;
    if (model.group != null &&
        last?.first.group == model.group &&
        last?.category == model.category) {
      last!.variants.add(model);
    } else {
      groups.add(ModelGroup([model]));
    }
  }
  return groups;
}();

/// The card [model] belongs to.
ModelGroup groupOf(ModelInfo model) =>
    modelGroups.firstWhere((g) => g.variants.any((m) => m.id == model.id));

/// Remote (folder, filename) pairs for the image demos, shared by the
/// still-image path, the realtime path, and the home screen badge so
/// each file name exists in exactly one place.
const Map<String, List<(String, String)>> imageModelFiles = {
  'yolox': [('yolox', 'yolox_s.opt.onnx')],
  'bytetrack': [('yolox', 'yolox_s.opt.onnx')],
  'detic': [('detic', 'Detic_C2_SwinB_896_4x_IN-21K+COCO_lvis_op16.onnx')],
  'lw-human-pose': [
    (
      'lightweight-human-pose-estimation',
      'lightweight-human-pose-estimation.opt.onnx'
    )
  ],
  'resnet50': [('resnet50', 'resnet50_pytorch.onnx')],
  'vit': [('vit', 'ViT-B_16-224.onnx')],
  'u2net': [('u2net', 'u2net_opset11.onnx')],
  'sam2': [
    ('segment-anything-2', 'image_encoder_hiera_t.onnx'),
    ('segment-anything-2', 'prompt_encoder_hiera_t.onnx'),
    ('segment-anything-2', 'mask_decoder_hiera_t.onnx'),
  ],
  'sam3.1': [
    ('segment-anything-3.1', 'sam3.1_image_encoder.opt.onnx'),
    ('segment-anything-3.1', 'sam3.1_grounding.onnx'),
  ],
};

IconData categoryIcon(String category) {
  switch (category) {
    case 'Image Classification':
      return Icons.image_search;
    case 'Image Segmentation':
      return Icons.auto_fix_high;
    case 'Background Removal':
      return Icons.filter_hdr;
    case 'Object Detection':
      return Icons.center_focus_strong;
    case 'Object Tracking':
      return Icons.route;
    case 'Pose Estimation':
      return Icons.accessibility_new;
    case 'Diffusion':
      return Icons.brush;
    case 'Audio Processing':
      return Icons.graphic_eq;
    case 'Speech To Text':
      return Icons.mic;
    case 'Natural Language Processing':
      return Icons.translate;
    case 'Text To Speech':
      return Icons.record_voice_over;
    case 'Tool Use':
      return Icons.build_outlined;
    case 'Voice Agent':
      return Icons.record_voice_over;
    case 'Large Language Model':
      return Icons.chat_bubble_outline;
    case 'VLM':
      return Icons.image_search;
    case 'ALM':
      return Icons.mic;
    default:
      return Icons.memory;
  }
}

Color categoryColor(BuildContext context, String category) {
  final scheme = Theme.of(context).colorScheme;
  switch (category) {
    case 'Image Classification':
    case 'Image Segmentation':
    case 'Background Removal':
    case 'Object Detection':
    case 'Object Tracking':
    case 'Pose Estimation':
      return scheme.primary;
    case 'Audio Processing':
    case 'Speech To Text':
      return scheme.tertiary;
    case 'Natural Language Processing':
      return scheme.secondary;
    case 'Text To Speech':
      return scheme.error;
    case 'Large Language Model':
    case 'VLM':
    case 'ALM':
    case 'Tool Use':
    case 'Voice Agent':
      return Colors.indigo;
    case 'Diffusion':
      return Colors.deepPurple;
    default:
      return scheme.outline;
  }
}
