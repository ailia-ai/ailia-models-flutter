import 'package:flutter/material.dart';

import '../backend_state.dart';
import '../model_catalog.dart';
import 'demo_screen.dart';

/// Top screen: a grid of model cards. Selecting a card navigates to the
/// demo screen for that model.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

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
          return ModelCard(model: model);
        },
      ),
    );
  }
}

class ModelCard extends StatelessWidget {
  const ModelCard({super.key, required this.model});

  final ModelInfo model;

  @override
  Widget build(BuildContext context) {
    final color = categoryColor(context, model.category);
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (context) => DemoScreen(model: model),
            ),
          );
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
              Align(
                alignment: Alignment.bottomRight,
                child: Icon(
                  Icons.play_circle_outline,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
