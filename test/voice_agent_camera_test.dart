import 'dart:io';

import 'package:ailia_models_flutter/screens/demo/voice_agent_camera_settings.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_camera.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const cameras = [
    CameraDescription(
      name: 'rear-wide',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
    CameraDescription(
      name: 'rear-tele',
      lensDirection: CameraLensDirection.back,
      sensorOrientation: 90,
    ),
    CameraDescription(
      name: 'front',
      lensDirection: CameraLensDirection.front,
      sensorOrientation: 270,
    ),
    CameraDescription(
      name: 'usb',
      lensDirection: CameraLensDirection.external,
      sensorOrientation: 0,
    ),
  ];
  test(
    'explicit device overrides facing, while automatic mobile selection respects facing',
    () {
      expect(selectVoiceAgentCamera(cameras, front: false).name, 'rear-wide');
      expect(selectVoiceAgentCamera(cameras, front: true).name, 'front');
      expect(
        selectVoiceAgentCamera(
          cameras,
          front: true,
          deviceId: 'rear-tele',
        ).name,
        'rear-tele',
      );
      expect(
        selectVoiceAgentCamera(cameras, front: false, deviceId: 'usb').name,
        'usb',
      );
    },
  );
  test('missing devices never silently switch to another camera', () {
    expect(
      () =>
          selectVoiceAgentCamera(cameras, front: false, deviceId: 'unplugged'),
      throwsStateError,
    );
    expect(
      () => selectVoiceAgentCamera([cameras.first], front: true),
      throwsStateError,
    );
    expect(
      selectVoiceAgentCamera(
        [cameras.last],
        front: false,
        requireFacing: false,
      ).name,
      'usb',
    );
  });

  const channel = MethodChannel('camera_macos');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          switch (call.method) {
            case 'listDevices':
              return {
                'devices': [
                  {
                    'deviceId': 'built-in',
                    'localizedName': '内蔵カメラ',
                    'deviceType': 0,
                  },
                  {
                    'deviceId': 'usb-b',
                    'localizedName': 'USB カメラ',
                    'deviceType': 0,
                  },
                ],
              };
            case 'initialize':
              return {
                'textureId': 1,
                'size': {'width': 640.0, 'height': 480.0},
                'devices': [],
              };
            case 'takePicture':
              return {
                'imageData': img.encodeJpg(img.Image(width: 8, height: 8)),
              };
            case 'destroy':
              return true;
          }
          throw MissingPluginException(call.method);
        });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'macOS enumeration preserves device names and IDs without initializing capture',
    () async {
      final devices = await voiceAgentCameraDevices();
      expect(devices.map((d) => d.id), ['built-in', 'usb-b']);
      expect(devices.map((d) => d.label), ['内蔵カメラ', 'USB カメラ']);
      expect(calls.map((c) => c.method), ['listDevices']);
    },
    skip: !Platform.isMacOS,
  );

  test(
    'macOS capture forwards the selected device and releases it',
    () async {
      final jpeg = await VoiceAgentCamera().capture(
        front: false,
        deviceId: 'usb-b',
        checkActive: () {},
      );
      final args =
          calls.singleWhere((c) => c.method == 'initialize').arguments as Map;
      expect(args['deviceId'], 'usb-b');
      expect(args['enableAudio'], isFalse);
      expect(args['isVideoMirrored'], isFalse);
      expect(img.decodeJpg(jpeg), isNotNull);
      expect(calls.last.method, 'destroy');
    },
    skip: !Platform.isMacOS,
  );

  test(
    'macOS rejects an unplugged selection before opening any camera',
    () async {
      await expectLater(
        VoiceAgentCamera().capture(
          front: false,
          deviceId: 'unplugged',
          checkActive: () {},
        ),
        throwsStateError,
      );
      expect(calls.map((c) => c.method), ['listDevices']);
    },
    skip: !Platform.isMacOS,
  );

  testWidgets(
    'desktop device enumeration happens only on request and selection is retained',
    (tester) async {
      String? selected;
      var requests = 0;
      var devices = const [
        VoiceAgentCameraDevice('a', '内蔵カメラ'),
        VoiceAgentCameraDevice('b', 'USB カメラ'),
      ];
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return VoiceAgentCameraSettings(
                  front: false,
                  deviceId: selected,
                  desktop: true,
                  onFrontChanged: (_) {},
                  onDeviceChanged: (value) => setState(() => selected = value),
                  loadDevices: () async {
                    requests++;
                    return devices;
                  },
                );
              },
            ),
          ),
        ),
      );
      expect(requests, 0);
      expect(find.text('アウトカメラ'), findsNothing);
      await tester.tap(find.text('カメラ一覧を取得'));
      await tester.pumpAndSettle();
      expect(requests, 1);
      await tester.tap(find.byKey(const ValueKey('撮影デバイス:')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('USB カメラ').last);
      await tester.pumpAndSettle();
      expect(selected, 'b');
      devices = const [VoiceAgentCameraDevice('a', '内蔵カメラ')];
      await tester.tap(find.text('カメラ一覧を取得'));
      await tester.pumpAndSettle();
      expect(selected, 'b');
      expect(find.text('選択したカメラ（未接続・未確認）'), findsOneWidget);
      update(() {
        selected = null;
      });
      await tester.pumpAndSettle();
      expect(find.text('システムの既定カメラ'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'permission errors are visible and leave automatic camera selection available',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoiceAgentCameraSettings(
              front: false,
              deviceId: null,
              desktop: true,
              onFrontChanged: (_) {},
              onDeviceChanged: (_) {},
              loadDevices: () async => throw StateError('Permission denied'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('カメラ一覧を取得'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Permission denied'), findsOneWidget);
      expect(find.text('システムの既定カメラ'), findsOneWidget);
    },
  );

  testWidgets('mobile keeps facing selection and explicit devices separate', (
    tester,
  ) async {
    var front = false;
    String? deviceId;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => VoiceAgentCameraSettings(
              front: front,
              deviceId: deviceId,
              desktop: false,
              onFrontChanged: (value) => update(() => front = value),
              onDeviceChanged: (value) => update(() => deviceId = value),
              loadDevices: () async => const [
                VoiceAgentCameraDevice('usb', 'USB カメラ'),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('カメラ:false')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('インカメラ').last);
    await tester.pumpAndSettle();
    expect(front, isTrue);
    await tester.tap(find.text('カメラ一覧を取得'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('撮影デバイス:')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USB カメラ').last);
    await tester.pumpAndSettle();
    expect(deviceId, 'usb');
    expect(
      tester
          .widget<DropdownButtonFormField<bool>>(
            find.byKey(const ValueKey('カメラ:true')),
          )
          .onChanged,
      isNull,
    );
    await tester.tap(find.byKey(const ValueKey('撮影デバイス:usb')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('前後カメラ設定に従う').last);
    await tester.pumpAndSettle();
    expect(deviceId, isNull);
    expect(front, isTrue);
    expect(
      tester
          .widget<DropdownButtonFormField<bool>>(
            find.byKey(const ValueKey('カメラ:true')),
          )
          .onChanged,
      isNotNull,
    );
  });
}
