import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ailia_models_flutter/model_catalog.dart';
import 'package:ailia_models_flutter/screens/demo/demo_session.dart';
import 'package:ailia_models_flutter/screens/demo/model_variant_selector.dart';

void main() {
  testWidgets('selector lists the card variants with QNN marks',
      (tester) async {
    final variants = modelGroups
        .singleWhere((g) => g.first.id == 'gemma2')
        .variants;
    ModelInfo? picked;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ModelVariantScope(
          variants: variants,
          selected: variants.first,
          onSelected: (m) => picked = m,
          child: ModelVariantSelector(session: DemoSession()),
        ),
      ),
    ));
    await tester.tap(find.text('Gemma 2 2B'));
    await tester.pumpAndSettle();

    for (final model in variants) {
      expect(find.text(model.selectorLabel), findsWidgets);
      expect(model.selectorLabel.endsWith(' [QNN]'), model.qnnAvailable);
    }
    // Gemma 2 has no QNN model; Gemma 4 E2B runs on QNN on any SoC.
    expect(variants.first.selectorLabel, 'Gemma 2 2B');
    expect(variants[1].selectorLabel, 'Gemma 4 E2B [QNN]');

    await tester.tap(find.text('Gemma 4 E2B [QNN]').last);
    await tester.pumpAndSettle();
    expect(picked?.id, 'gemma4-e2b');
  });

  testWidgets('single-model cards show no selector', (tester) async {
    final model = modelCatalog.singleWhere((m) => m.id == 'resnet50');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ModelVariantScope(
          variants: [model],
          selected: model,
          onSelected: (_) {},
          child: ModelVariantSelector(session: DemoSession()),
        ),
      ),
    ));
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
  });
}
