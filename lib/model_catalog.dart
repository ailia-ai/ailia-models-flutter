import 'package:flutter/material.dart';

/// What kind of input the demo consumes. Used to decide which input
/// source toggle (image/webcam or audio/mic) is shown on the demo screen.
enum ModelInputKind { image, audio, text, imageText }

class ModelInfo {
  final String id;
  final String name;
  final String category;
  final ModelInputKind input;

  const ModelInfo(this.id, this.name, this.category, this.input);
}

const List<ModelInfo> modelCatalog = [
  ModelInfo('resnet18', 'ResNet18', 'Image Classification', ModelInputKind.image),
  ModelInfo('sam2', 'Segment Anything 2', 'Image Segmentation', ModelInputKind.image),
  ModelInfo('u2net', 'U-2-Net', 'Background Removal', ModelInputKind.image),
  ModelInfo('yolox', 'YOLOX', 'Object Detection', ModelInputKind.image),
  ModelInfo('whisper_tiny', 'Whisper Tiny', 'Audio Processing', ModelInputKind.audio),
  ModelInfo('whisper_small', 'Whisper Small', 'Audio Processing', ModelInputKind.audio),
  ModelInfo('whisper_medium', 'Whisper Medium', 'Audio Processing', ModelInputKind.audio),
  ModelInfo('whisper_large_v3_turbo', 'Whisper Large V3 Turbo', 'Audio Processing', ModelInputKind.audio),
  ModelInfo('sensevoice_small', 'SenseVoice Small', 'Audio Processing', ModelInputKind.audio),
  ModelInfo('multilingual-e5', 'Multilingual-E5', 'Natural Language Processing', ModelInputKind.text),
  ModelInfo('fugumt-en-ja', 'FuguMT EN-JA', 'Natural Language Processing', ModelInputKind.text),
  ModelInfo('fugumt-ja-en', 'FuguMT JA-EN', 'Natural Language Processing', ModelInputKind.text),
  ModelInfo('tacotron2', 'Tacotron2', 'Text To Speech', ModelInputKind.text),
  ModelInfo('gpt-sovits-ja', 'GPT-SoVITS JA', 'Text To Speech', ModelInputKind.text),
  ModelInfo('gpt-sovits-en', 'GPT-SoVITS EN', 'Text To Speech', ModelInputKind.text),
  ModelInfo('gemma2', 'Gemma 2 2B', 'Large Language Model', ModelInputKind.text),
  ModelInfo('gemma3-multimodal', 'Gemma 3 4B Multimodal', 'Large Language Model', ModelInputKind.imageText),
];

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
    case 'Audio Processing':
      return Icons.graphic_eq;
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
      return scheme.primary;
    case 'Audio Processing':
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
