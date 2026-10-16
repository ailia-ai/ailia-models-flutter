import 'package:ailia_models_flutter/license_error_dialog.dart';
import 'package:ailia_models_flutter/sdk_status.dart';
import 'package:flutter_test/flutter_test.dart';

String licenseFile(String date) =>
    '--- shalo license file ---\naxell:ailia\n$date\nprivate user data\n';

void main() {
  test(
    'recognizes SDK license codes, including errors forwarded by isolates',
    () {
      for (final code in [-20, -21, -22]) {
        for (final error in [
          Exception('ailiaCreate failed $code'),
          StateError('Exception: ailiaOpenWeightFile failed $code model.onnx'),
          Exception('ailiaLLMCreate returned an error status $code'),
          Exception('ailiaSpeechCreate failed $code \n detail license'),
          StateError('SetPromptJson failed: $code'),
        ]) {
          expect(isAiliaLicenseError(error), isTrue, reason: '$error');
        }
      }
    },
  );

  test('leaves unrelated errors in the existing error flow', () {
    for (final error in [
      Exception('ailiaCreate failed -1'),
      Exception('ailiaCreate failed -200'),
      Exception('ailiaOpenWeightFile failed -3 /models/test-20.onnx'),
      Exception('Download failed: HTTP 403'),
      Exception('License file download failed'),
      Exception('Microphone permission denied'),
      Exception('File not found: /models/-20'),
    ]) {
      expect(isAiliaLicenseError(error), isFalse, reason: '$error');
    }
  });

  test('reads just the expiry line with either line ending', () {
    for (final contents in [
      licenseFile('2026/10/17'),
      licenseFile('2026/10/17').replaceAll('\n', '\r\n'),
    ]) {
      expect(licenseExpiry(contents), '2026/10/17');
    }
    expect(licenseExpiry(null), 'Not found');
    expect(licenseExpiry('invalid header\n2026/10/17'), 'Unavailable');
    expect(licenseExpiry(licenseFile('')), 'Unavailable');
  });

  test('refreshes read-only information after a file changes', () async {
    var contents = licenseFile('2020/01/01');
    final status = SdkStatus(
      readVersion: () => 'ailia-sdk-1.6.1-test-build',
      readLicense: () async => contents,
    );
    addTearDown(status.dispose);
    await status.refresh();
    expect(status.version, 'ailia-sdk-1.6.1-test-build');
    expect(status.expiry, '2020/01/01');
    contents = licenseFile('2099/12/31');
    await status.refresh();
    expect(status.expiry, '2099/12/31');
  });

  test('perpetual SDKs do not require a license file', () async {
    final status = SdkStatus(
      readVersion: () => '1.6.1 perpetual_license',
      readLicense: () => throw StateError('Must not read a file'),
    );
    addTearDown(status.dispose);
    await status.refresh();
    expect(status.expiry, 'Perpetual');
  });
}
