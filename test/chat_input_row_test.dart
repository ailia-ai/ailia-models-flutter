import 'package:ailia_models_flutter/screens/demo/chat_bubble.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<int Function()> pumpRow(WidgetTester tester,
      {bool busy = false}) async {
    var sent = 0;
    final controller = TextEditingController(text: 'hello');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ChatInputRow(
                controller: controller, onSend: busy ? null : () => sent++))));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    return () => sent;
  }

  Future<void> press(WidgetTester tester, LogicalKeyboardKey modifier,
      [LogicalKeyboardKey key = LogicalKeyboardKey.enter]) async {
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(key);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
  }

  testWidgets('Cmd+Enter sends on macOS', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final sent = await pumpRow(tester);
      await press(tester, LogicalKeyboardKey.controlLeft);
      expect(sent(), 0);
      await press(tester, LogicalKeyboardKey.metaLeft);
      expect(sent(), 1);
      await press(
          tester, LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.numpadEnter);
      expect(sent(), 2);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('Ctrl+Enter sends on Windows', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final sent = await pumpRow(tester);
      await press(tester, LogicalKeyboardKey.metaLeft);
      expect(sent(), 0);
      await press(tester, LogicalKeyboardKey.controlLeft);
      expect(sent(), 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('the shortcut does nothing while sending is disabled',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final sent = await pumpRow(tester, busy: true);
      await press(tester, LogicalKeyboardKey.controlLeft);
      expect(sent(), 0);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
