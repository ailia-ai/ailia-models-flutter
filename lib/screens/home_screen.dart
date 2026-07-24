import 'dart:io';

import 'package:flutter/material.dart';

import '../model_catalog.dart';
import '../utils/download_model.dart';
import 'demo_screen.dart';

/// Representative file per model, used to show a "downloaded" badge on
/// the model card. Paths are relative to the app's model directory.
/// Image demos derive their marker from [imageModelFiles]; the entries
/// here cover the remaining models (using a file unique to each model,
/// e.g. the language-specific dictionary for GPT-SoVITS EN/ZH).
const Map<String, String> _markerFiles = {
  'whisper_tiny': 'encoder_tiny.opt3.onnx',
  'whisper_small': 'encoder_small.opt3.onnx',
  'whisper_medium': 'encoder_medium.opt3.onnx',
  'whisper_large_v3_turbo': 'encoder_turbo.onnx',
  'sensevoice_small': 'sensevoice_small.onnx',
  'multilingual-e5': 'multilingual-e5-base.onnx',
  'fugumt-en-ja': 'fugumt-en-ja/seq2seq-lm-with-past.onnx',
  'fugumt-ja-en': 'fugumt-ja-en/encoder_model.onnx',
  'tacotron2': 'waveglow.onnx',
  'gpt-sovits-ja': 'vits.onnx',
  'gpt-sovits-en': 'homographs.en',
  'gpt-sovits-zh': 'jieba.dict.utf8',
  'sdxl': 'sdxl/sdxl_unet_fp16.onnx',
  'gemma2': 'gemma-2-2b-it-Q4_K_M.gguf',
  'gemma4-e2b': 'gemma-4-E2B-it-Q4_K_M.gguf',
  'gemma3-multimodal': 'gemma-3-4b-it-Q4_K_M.gguf',
};

/// Top screen: model cards grouped by category. Selecting a card
/// navigates to the demo screen for that model.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Set<String> _downloaded = {};

  @override
  void initState() {
    super.initState();
    _refreshDownloaded();
    _openModelFromEnvironment();
  }

  /// Automation hook: AILIA_OPEN_MODEL=<model id> opens that demo
  /// screen on startup (used together with AILIA_SCREENSHOT).
  void _openModelFromEnvironment() {
    final id = Platform.environment['AILIA_OPEN_MODEL'];
    if (id == null || id.isEmpty) {
      return;
    }
    final model = modelCatalog.where((m) => m.id == id).firstOrNull;
    if (model == null) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Navigator.of(context).push(
        MaterialPageRoute(builder: (context) => DemoScreen(model: model)),
      );
    });
  }

  Future<void> _refreshDownloaded() async {
    // Resolve the model directory once instead of a platform-channel
    // round trip per model.
    final base = await getModelPath('');
    final markers = {
      for (final entry in imageModelFiles.entries)
        entry.key: entry.value.first.$2,
      ..._markerFiles,
    };
    final downloaded = <String>{};
    for (final entry in markers.entries) {
      if (File('$base${entry.value}').existsSync()) {
        downloaded.add(entry.key);
      }
    }
    if (mounted) {
      setState(() {
        _downloaded = downloaded;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('ailia MODELS Flutter'),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 260,
          mainAxisExtent: 140,
          crossAxisSpacing: 12,
          mainAxisSpacing: 12,
        ),
        itemCount: modelCatalog.length,
        itemBuilder: (context, index) {
          final model = modelCatalog[index];
          return ModelCard(
            model: model,
            downloaded: _downloaded.contains(model.id),
            onReturned: _refreshDownloaded,
          );
        },
      ),
    );
  }
}

class ModelCard extends StatelessWidget {
  const ModelCard({
    super.key,
    required this.model,
    this.downloaded = false,
    this.onReturned,
  });

  final ModelInfo model;
  final bool downloaded;
  final VoidCallback? onReturned;

  @override
  Widget build(BuildContext context) {
    final color = categoryColor(context, model.category);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context)
              .push(
                MaterialPageRoute(
                  builder: (context) => DemoScreen(model: model),
                ),
              )
              .then((_) => onReturned?.call());
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(categoryIcon(model.category), size: 18, color: color),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      model.category,
                      style: Theme.of(context)
                          .textTheme
                          .labelSmall
                          ?.copyWith(color: color),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                model.name,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  if (downloaded)
                    Tooltip(
                      message: 'Model downloaded',
                      child: Icon(
                        Icons.download_done,
                        size: 18,
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                    ),
                  const Spacer(),
                  Icon(
                    Icons.play_circle_outline,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
