import 'package:ailia_models_flutter/large_language_model/qnn_model.dart';
import 'package:ailia_models_flutter/screens/demo/mtp_switch.dart';
import 'package:ailia_models_flutter/screens/settings_screen.dart';
import 'package:ailia_models_flutter/sdk_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('QNN model format switches between v1.5.1 and v1.5.0',
      (tester) async {
    addTearDown(() => qnnModelFormat = QnnModelFormat.v151);
    final status = SdkStatus(
      readVersion: () => 'ailia-sdk-test',
      readLicense: () async => null,
    );
    addTearDown(status.dispose);
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(status: status)),
    );
    expect(find.text('Debug options'), findsOneWidget);
    expect(qnnModelFormat, QnnModelFormat.v151);

    await tester.tap(find.text('v1.5.0'));
    await tester.pump();
    expect(qnnModelFormat, QnnModelFormat.v150);
    expect(qnnTextModelFiles('gemma4-e2b', 'sc8380xp')[1],
        'gemma4-e2b-sc8380xp.qnn');

    await tester.tap(find.text('v1.5.1'));
    await tester.pump();
    expect(qnnModelFormat, QnnModelFormat.v151);
  });

  testWidgets('unavailable MTP switch is off and cannot be changed',
      (tester) async {
    var changed = false;
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MtpSwitch(
                value: true,
                available: false,
                onChanged: (_) => changed = true))));
    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.value, isFalse);
    expect(toggle.onChanged, isNull);
    await tester.tap(find.byType(Switch));
    expect(changed, isFalse);
  });
}
