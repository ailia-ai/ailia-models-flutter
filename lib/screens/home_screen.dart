import 'dart:io';

import 'package:flutter/material.dart';

import '../backend_state.dart';
import '../model_catalog.dart';
import '../utils/download_model.dart';
import 'demo_screen.dart';

/// Representative file per model, used to show a "downloaded" badge on
/// the model card. Paths are relative to the app's model directory.
const Map<String, String> _markerFiles = {
  'resnet18': 'resnet18.onnx',
  'sam2': 'image_encoder_hiera_t.onnx',
  'u2net': 'u2net.onnx',
  'yolox': 'yolox_s.opt.onnx',
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
  'gpt-sovits-en': 'vits.onnx',
  'gpt-sovits-zh': 'jieba.dict.utf8',
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
  }

  Future<void> _refreshDownloaded() async {
    final downloaded = <String>{};
    for (final entry in _markerFiles.entries) {
      final path = await getModelPath(entry.value);
      if (File(path).existsSync()) {
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
        actions: const [BackendSelector()],
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
