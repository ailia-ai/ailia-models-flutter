import 'package:flutter/material.dart';

import '../../model_catalog.dart';
import 'demo_session.dart';

/// Provides the variants of the open card to the demo page scaffold, so
/// a card that groups several models (Whisper sizes, GPT-SoVITS
/// languages, ...) can switch between them inside the demo.
class ModelVariantScope extends InheritedWidget {
  const ModelVariantScope({
    super.key,
    required this.variants,
    required this.selected,
    required this.onSelected,
    required super.child,
  });

  final List<ModelInfo> variants;
  final ModelInfo selected;
  final ValueChanged<ModelInfo> onSelected;

  static ModelVariantScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ModelVariantScope>();

  @override
  bool updateShouldNotify(ModelVariantScope oldWidget) =>
      variants != oldWidget.variants || selected.id != oldWidget.selected.id;
}

/// Model dropdown shown when the open card groups several models.
/// QNN-ready variants are marked with "[QNN]". Disabled while a run or
/// a download is in flight; a change reopens the demo page for the
/// selected model.
class ModelVariantSelector extends StatelessWidget {
  const ModelVariantSelector({super.key, required this.session});

  final DemoSession session;

  @override
  Widget build(BuildContext context) {
    final scope = ModelVariantScope.maybeOf(context);
    if (scope == null || scope.variants.length < 2) {
      return const SizedBox.shrink();
    }
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final busy = session.processing || session.status.isNotEmpty;
        return DemoPanel(
          margin: const EdgeInsets.only(bottom: 8),
          child: DropdownButtonFormField<String>(
            initialValue: scope.selected.id,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Model',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              for (final model in scope.variants)
                DropdownMenuItem(
                  value: model.id,
                  child: Text(
                    model.selectorLabel,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: busy
                ? null
                : (id) {
                    final model = scope.variants
                        .where((m) => m.id == id)
                        .firstOrNull;
                    if (model != null && model.id != scope.selected.id) {
                      scope.onSelected(model);
                    }
                  },
          ),
        );
      },
    );
  }
}
