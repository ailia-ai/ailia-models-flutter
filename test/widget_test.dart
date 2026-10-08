import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ailia_models_flutter/main.dart';
import 'package:ailia_models_flutter/screens/home_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;

  setUp(() {
    documents = Directory.systemTemp.createTempSync('ailia-models-widget-');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return documents.path;
      }
      throw MissingPluginException(call.method);
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    documents.deleteSync(recursive: true);
  });

  testWidgets('home lists models including Gemma 4 E2B Tool Use',
      (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('ailia MODELS Flutter'), findsOneWidget);
    expect(find.text('ResNet50'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Gemma 4 E2B Tool Use'), 400,
        scrollable: find.byType(Scrollable));
    final card = tester.widget<ModelCard>(find.ancestor(
        of: find.text('Gemma 4 E2B Tool Use'),
        matching: find.byType(ModelCard)));
    expect(card.model.category, 'Tool Use');
    expect(card.model.usesLlmBackend, isTrue);
    expect(tester.takeException(), isNull);
  });
  for (final filename in [
    'gemma-4-E2B-it-Q4_K_M.gguf',
    'gemma4-e2b-sc8380xp.qnn',
    'gemma4-e2b-qcs6490.qnn',
  ]) {
    testWidgets('Tool Use shares the downloaded marker for $filename',
        (tester) async {
      final directory =
          Directory('${documents.path}/ailia MODELS flutter/models')
            ..createSync(recursive: true);
      File('${directory.path}/$filename').writeAsBytesSync([]);
      await tester.pumpWidget(const MyApp());
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Gemma 4 E2B Tool Use'), 400,
          scrollable: find.byType(Scrollable));
      final card = tester.widget<ModelCard>(find.ancestor(
          of: find.text('Gemma 4 E2B Tool Use'),
          matching: find.byType(ModelCard)));
      expect(card.downloaded, isTrue);
    });
  }
}
