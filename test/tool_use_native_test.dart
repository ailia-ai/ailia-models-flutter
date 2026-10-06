// Opt-in smoke test with the SDK library on the platform's library search path:
// AILIA_TOOL_USE_MODEL=/path/to/gemma-4-E2B-it-Q4_K_M.gguf
// AILIA_TOOL_USE_BACKEND=Metal flutter test test/tool_use_native_test.dart
// On macOS, set DYLD_LIBRARY_PATH to the built app's Contents/Frameworks.
// Launch Flutter via the Dart binary to retain that variable across startup:
// $FLUTTER_ROOT/bin/cache/dart-sdk/bin/dart \
//   $FLUTTER_ROOT/bin/cache/flutter_tools.snapshot test --no-pub \
//   test/tool_use_native_test.dart
import 'dart:io';

import 'package:ailia_llm/ailia_llm_model.dart';

import 'package:ailia_models_flutter/large_language_model/tool_use_worker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final path = Platform.environment['AILIA_TOOL_USE_MODEL'];
  final backend = Platform.environment['AILIA_TOOL_USE_BACKEND'] ?? 'CPU';
  test('Gemma 4 E2B executes tools with thinking off and on', () async {
    final worker = ToolUseWorker();
    try {
      final name = AiliaLLMModel.getBackendList().firstWhere(
          (name) => name == backend || name.startsWith('$backend:'));
      await worker.start(path!, name);
      for (final (thinking, temperature) in [(false, 20), (true, 22)]) {
        double? actual;
        var answer = '';
        await worker.chat('エアコンの温度を$temperature度にしてください', thinking, (event) {
          if (event['type'] == 'tool') actual = event['temperature'] as double?;
          if (event['type'] == 'turnComplete') {
            answer = event['content'] as String;
          }
        });
        expect(actual, temperature);
        expect(answer.trim(), isNotEmpty);
      }
    } finally {
      worker.dispose();
    }
  },
      skip: path == null
          ? 'Set AILIA_TOOL_USE_MODEL to run native inference'
          : false,
      timeout: const Timeout(Duration(minutes: 6)));
}
