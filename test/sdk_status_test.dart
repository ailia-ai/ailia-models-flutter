import 'dart:async';

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
      expect(isAiliaLicenseError('AILIA_STATUS_LICENSE_NOT_FOUND'), isTrue);
      expect(
        isAiliaLicenseError(Exception('License file download failed')),
        isTrue,
      );
    },
  );

  test(
    'does not mistake model, download or file path errors for license codes',
    () {
      for (final error in [
        Exception('ailiaCreate failed -1'),
        Exception('ailiaCreate failed -200'),
        Exception('ailiaOpenWeightFile failed -3 /models/test-20.onnx'),
        Exception('Download failed: HTTP 403'),
        Exception('Microphone permission denied'),
        Exception('File not found: /models/-20'),
      ]) {
        expect(isAiliaLicenseError(error), isFalse, reason: '$error');
      }
    },
  );

  test(
    'reads the license date with either line ending and includes the last day',
    () {
      for (final contents in [
        licenseFile('2026/10/17'),
        licenseFile('2026/10/17').replaceAll('\n', '\r\n'),
      ]) {
        final current = LicenseInfo.parse(
          contents,
          now: DateTime(2026, 10, 17, 23),
        );
        expect(current.state, LicenseState.valid);
        expect(current.label, '2026/10/17');
        final expired = LicenseInfo.parse(
          contents,
          now: DateTime(2026, 10, 18),
        );
        expect(expired.state, LicenseState.expired);
        expect(expired.label, '2026/10/17（期限切れ）');
        expect(expired.label, isNot(contains('private user data')));
      }
    },
  );

  test(
    'distinguishes a missing license from malformed or impossible dates',
    () {
      expect(LicenseInfo.parse(null).state, LicenseState.missing);
      for (final contents in [
        '',
        'invalid header\n2026/10/17',
        licenseFile(''),
        licenseFile('2026/02/30'),
        licenseFile('2026/13/01'),
      ]) {
        expect(LicenseInfo.parse(contents).state, LicenseState.invalid);
      }
    },
  );

  test('refreshes the expiry after a license file is renewed', () async {
    var contents = licenseFile('2020/01/01');
    final status = SdkStatus(
      readVersion: () => '1.6.1-test-build',
      readLicense: () async => contents,
    );
    addTearDown(status.dispose);
    await status.refresh();
    expect(status.version, '1.6.1-test-build');
    expect(status.license!.state, LicenseState.expired);
    contents = licenseFile('2099/12/31');
    await status.refresh();
    expect(status.license!.label, '2099/12/31');
    expect(status.license!.state, LicenseState.valid);
  });

  test('perpetual SDKs do not require a license file', () async {
    final status = SdkStatus(
      readVersion: () => '1.6.1 perpetual_license',
      readLicense: () => throw StateError('Must not read a file'),
    );
    addTearDown(status.dispose);
    await status.refresh();
    expect(status.license!.state, LicenseState.perpetual);
    expect(status.license!.label, '無期限');
  });

  test('native and file read failures leave the UI usable', () async {
    final status = SdkStatus(
      readVersion: () => throw ArgumentError('SDK unavailable'),
      readLicense: () => throw StateError('Permission denied'),
    );
    addTearDown(status.dispose);
    await status.refresh();
    expect(status.version, isNull);
    expect(status.license!.state, LicenseState.unavailable);
  });

  test('concurrent refreshes share the same file read', () async {
    final contents = Completer<String?>();
    var reads = 0;
    final status = SdkStatus(
      readVersion: () => '1.6.1',
      readLicense: () {
        reads++;
        return contents.future;
      },
    );
    addTearDown(status.dispose);
    final first = status.refresh();
    final second = status.refresh();
    contents.complete(null);
    await Future.wait([first, second]);
    expect(reads, 1);
    expect(status.license!.state, LicenseState.missing);
  });
}
