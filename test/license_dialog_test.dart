import 'package:ailia_models_flutter/license_error_dialog.dart';
import 'package:ailia_models_flutter/screens/demo/demo_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late DemoSession session;

  setUp(() => session = DemoSession());
  tearDown(() => session.dispose());

  Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(navigatorKey: appNavigatorKey, home: const Scaffold()),
  );

  testWidgets('displays the requested dialog for each license error', (
    tester,
  ) async {
    await pumpApp(tester);
    for (final code in [-20, -21, -22]) {
      session.showError(StateError('Exception: ailiaCreate failed $code'));
      await tester.pumpAndSettle();
      expect(find.text('ライセンスファイルが見つかりません'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    }
  });

  testWidgets('does not stack dialogs on repeated errors or progress', (
    tester,
  ) async {
    await pumpApp(tester);
    session.showError(Exception('ailiaLLMCreate returned an error status -20'));
    await tester.pumpAndSettle();
    session.setStatus('Stopping...');
    session.showError(Exception('ailiaCreate failed -20'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    session.showError(Exception('ailiaCreate failed -20'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  });

  testWidgets('keeps unrelated errors in the ordinary error flow', (
    tester,
  ) async {
    await pumpApp(tester);
    session.showError(Exception('ailiaCreate failed -1'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(session.errorText, contains('ailiaCreate failed -1'));
  });

  testWidgets('does not show a dialog after the app is removed', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    session.showError(Exception('ailiaCreate failed -20'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
