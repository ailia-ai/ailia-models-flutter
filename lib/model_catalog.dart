import 'package:flutter/material.dart';

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

  const ModelInfo(this.id, this.name, this.category, this.input,
      {this.sampleAsset, this.defaultInputText, this.qnnSupported = false});

  bool get isSpeechToText => category == 'Speech To Text';
  bool get isTextToSpeech => category == 'Text To Speech';

  /// Text-only LLMs get the multi-turn chat UI.
  bool get isChat =>
      category == 'Large Language Model' && input == ModelInputKind.text;
}

const List<ModelInfo> modelCatalog = [
  ModelInfo(
      'resnet50', 'ResNet50', 'Image Classification', ModelInputKind.image,
      sampleAsset: 'assets/clock.jpg', qnnSupported: true),
  ModelInfo(
      'sam2', 'Segment Anything 2', 'Image Segmentation', ModelInputKind.image,
      sampleAsset: 'assets/truck.jpg'),
  ModelInfo('sam3.1', 'Segment Anything 3.1', 'Image Segmentation',
      ModelInputKind.image,
      sampleAsset: 'assets/truck.jpg', defaultInputText: 'truck'),
  ModelInfo('u2net', 'U-2-Net', 'Background Removal', ModelInputKind.image,
      sampleAsset: 'assets/input_u2net.png', qnnSupported: true),
  ModelInfo('yolox', 'YOLOX', 'Object Detection', ModelInputKind.image,
      sampleAsset: 'assets/clock.jpg', qnnSupported: true),
  ModelInfo('detic', 'Detic', 'Object Detection', ModelInputKind.image,
      sampleAsset: 'assets/desk.jpg'),
  ModelInfo('bytetrack', 'ByteTrack', 'Object Tracking', ModelInputKind.image,
      sampleAsset: 'assets/clock.jpg'),
  ModelInfo(
      'whisper_tiny', 'Whisper Tiny', 'Speech To Text', ModelInputKind.audio),
  ModelInfo(
      'whisper_small', 'Whisper Small', 'Speech To Text', ModelInputKind.audio),
  ModelInfo('whisper_medium', 'Whisper Medium', 'Speech To Text',
      ModelInputKind.audio),
  ModelInfo('whisper_large_v3_turbo', 'Whisper Large V3 Turbo',
      'Speech To Text', ModelInputKind.audio),
  ModelInfo('sensevoice_small', 'SenseVoice Small', 'Speech To Text',
      ModelInputKind.audio, qnnSupported: true),
  ModelInfo('multilingual-e5', 'Multilingual-E5', 'Natural Language Processing',
      ModelInputKind.text),
  ModelInfo('fugumt-en-ja', 'FuguMT EN-JA', 'Natural Language Processing',
      ModelInputKind.text,
      defaultInputText: 'Hello world.'),
  ModelInfo('fugumt-ja-en', 'FuguMT JA-EN', 'Natural Language Processing',
      ModelInputKind.text,
      defaultInputText: 'こんにちは世界。'),
  ModelInfo('tacotron2', 'Tacotron2', 'Text To Speech', ModelInputKind.text,
      defaultInputText: 'Hello world.'),
  ModelInfo(
      'gpt-sovits-ja', 'GPT-SoVITS JA', 'Text To Speech', ModelInputKind.text,
      defaultInputText: 'こんにちは。今日はいい天気ですね。'),
  ModelInfo(
      'gpt-sovits-en', 'GPT-SoVITS EN', 'Text To Speech', ModelInputKind.text,
      defaultInputText: 'Hello world.'),
  ModelInfo(
      'gpt-sovits-zh', 'GPT-SoVITS ZH', 'Text To Speech', ModelInputKind.text,
      defaultInputText: '你好世界。'),
  ModelInfo('gpt-sovits-v2pro-distill-ja', 'GPT-SoVITS V2Pro Distill JA',
      'Text To Speech', ModelInputKind.text,
      defaultInputText: 'こんにちは。今日はいい天気ですね。'),
  ModelInfo(
      'gemma2', 'Gemma 2 2B', 'Large Language Model', ModelInputKind.text),
  ModelInfo(
      'gemma4-e2b', 'Gemma 4 E2B', 'Large Language Model', ModelInputKind.text),
  ModelInfo('gemma3-multimodal', 'Gemma 3 4B Multimodal',
      'Large Language Model', ModelInputKind.imageText),
];

/// Remote (folder, filename) pairs for the image demos, shared by the
/// still-image path, the realtime path, and the home screen badge so
/// each file name exists in exactly one place.
const Map<String, List<(String, String)>> imageModelFiles = {
  'yolox': [('yolox', 'yolox_s.opt.onnx')],
  'bytetrack': [('yolox', 'yolox_s.opt.onnx')],
  'detic': [('detic', 'Detic_C2_SwinB_896_4x_IN-21K+COCO_lvis_op16.onnx')],
  'resnet50': [('resnet50', 'resnet50_pytorch.onnx')],
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
    case 'Audio Processing':
      return Icons.graphic_eq;
    case 'Speech To Text':
      return Icons.mic;
    case 'Natural Language Processing':
      return Icons.translate;
    case 'Text To Speech':
      return Icons.record_voice_over;
    case 'Large Language Model':
      return Icons.chat_bubble_outline;
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
      return scheme.primary;
    case 'Audio Processing':
    case 'Speech To Text':
      return scheme.tertiary;
    case 'Natural Language Processing':
      return scheme.secondary;
    case 'Text To Speech':
      return scheme.error;
    case 'Large Language Model':
      return Colors.indigo;
    default:
      return scheme.outline;
  }
}
