import 'package:ailia_models_flutter/screens/sdk_status_actions.dart';
import 'package:ailia_models_flutter/sdk_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late SdkStatus status;

  setUp(() {
    status = SdkStatus(
      readVersion: () => 'ailia-sdk-1.6.1-test-build',
      readLicense: () async =>
          '--- shalo license file ---\naxell:ailia\n2099/12/31\n',
    );
  });
  tearDown(() => status.dispose());

  Future<void> pumpActions(WidgetTester tester) async {
    await status.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          appBar: AppBar(
            title: const Text('ailia MODELS Flutter'),
            actions: [SdkStatusActions(status: status)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('shows native version and expiry to the left of Settings', (
    tester,
  ) async {
    await pumpActions(tester);
    final version = find.text('ailia-sdk-1.6.1-test-build');
    final expiry = find.text('License expiration: 2099/12/31');
    final settings = find.byIcon(Icons.settings);
    expect(version, findsOneWidget);
    expect(expiry, findsOneWidget);
    expect(
      tester.getRect(version).right,
      lessThan(tester.getRect(settings).left),
    );
    expect(
      tester.getRect(expiry).right,
      lessThan(tester.getRect(settings).left),
    );
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('ailia-sdk-1.6.1-test-build'), findsOneWidget);
    expect(find.text('2099/12/31'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('fits a narrow title bar with a long SDK version', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    status.dispose();
    status = SdkStatus(
      readVersion: () =>
          '1.6.1 very long native build and revision information',
      readLicense: () async => null,
    );
    await pumpActions(tester);
    expect(find.text('License expiration: Not found'), findsOneWidget);
    expect(find.byIcon(Icons.settings), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
