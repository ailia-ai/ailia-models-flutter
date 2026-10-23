import 'package:ailia/ailia_model.dart';
import 'package:ailia_models_flutter/screens/demo/voice_agent_demo_page.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_config.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_controller.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAgent extends VoiceAgentController {
  VoiceAgentConfig? config;
  int stops = 0;
  @override
  Future<void> start(VoiceAgentConfig config) async {
    this.config = config;
    active = true;
    state = VoiceAgentState.listening;
    input = 'こんにちは';
    output = 'こんにちは。';
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    stops++;
    active = false;
    notifyListeners();
  }
}

void main() {
  late FakeAgent agent;
  Widget page({Future<List<VoiceAgentCameraDevice>> Function()? cameras}) =>
      MaterialApp(
        home: VoiceAgentDemoPage(
          controller: agent,
          environments: [
            AiliaEnvironment()
              ..id = 0
              ..name = 'CPU',
            AiliaEnvironment()
              ..id = 1
              ..name = 'GPU',
          ],
          llmBackends: const ['CPU', 'Metal'],
          cameraDeviceLoader: cameras,
        ),
      );
  setUp(() {
    agent = FakeAgent();
  });

  testWidgets('setup remembers MTP separately for E2B and E4B', (tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(page());
    SwitchListTile mtp() => tester.widget<SwitchListTile>(
      find.ancestor(
        of: find.text('MTP'),
        matching: find.byType(SwitchListTile),
      ),
    );
    expect(mtp().value, isTrue);
    await tester.ensureVisible(find.byKey(const ValueKey('応答モデル:gemma4-e2b')));
    await tester.tap(find.byKey(const ValueKey('応答モデル:gemma4-e2b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gemma 4 E4B').last);
    await tester.pumpAndSettle();
    expect(mtp().value, isFalse);
    await tester.ensureVisible(find.text('MTP'));
    await tester.tap(find.text('MTP'));
    await tester.pumpAndSettle();
    expect(mtp().value, isTrue);
    await tester.ensureVisible(find.byKey(const ValueKey('応答モデル:gemma4-e4b')));
    await tester.tap(find.byKey(const ValueKey('応答モデル:gemma4-e4b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Gemma 4 E2B').last);
    await tester.pumpAndSettle();
    expect(mtp().value, isTrue);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'text-only microphone disables voice backend but test mode enables it',
    (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(page());
      await tester.ensureVisible(find.text('応答の音声合成'));
      await tester.tap(find.text('応答の音声合成'));
      await tester.pumpAndSettle();
      DropdownButtonFormField<int> voice() =>
          tester.widget(find.byKey(const ValueKey('音声合成バックエンド:0')));
      expect(voice().onChanged, isNull);
      await tester.ensureVisible(find.text('テスト：GPT-SoVITS合成音声'));
      await tester.tap(find.text('テスト：GPT-SoVITS合成音声'));
      await tester.pumpAndSettle();
      expect(voice().onChanged, isNotNull);
      await tester.ensureVisible(find.text('開始'));
      await tester.tap(find.text('開始'));
      await tester.pump();
      expect(agent.config!.testMode, isTrue);
      expect(agent.config!.speechOutput, isFalse);
      expect(agent.config!.queries, hasLength(2));
      expect(find.byType(AppBar), findsNothing);
      expect(find.byType(VoiceAgentOrb), findsOneWidget);
      expect(find.text('こんにちは'), findsOneWidget);
      await tester.tap(find.byTooltip('対話を終了'));
      await tester.pumpAndSettle();
      expect(find.text('開始'), findsOneWidget);
    },
  );
  testWidgets('backgrounding ends capture and playback', (tester) async {
    await tester.pumpWidget(page());
    await agent.start(
      const VoiceAgentConfig(speechEnvId: 0, voiceEnvId: 0, llmBackend: 'CPU'),
    );
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(agent.active, isFalse);
    expect(agent.stops, greaterThan(0));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('selected camera is passed to the voice session configuration', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      page(
        cameras: () async => const [VoiceAgentCameraDevice('usb-b', 'USB カメラ')],
      ),
    );
    await tester.ensureVisible(find.text('カメラ一覧を取得'));
    await tester.tap(find.text('カメラ一覧を取得'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('撮影デバイス:')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('USB カメラ').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('開始'));
    await tester.tap(find.text('開始'));
    await tester.pump();
    expect(agent.config!.cameraDeviceId, 'usb-b');
    await tester.tap(find.byTooltip('対話を終了'));
    await tester.pumpAndSettle();
    expect(find.text('USB カメラ'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('call layout fits a narrow phone', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    agent.active = true;
    agent.state = VoiceAgentState.preparing;
    agent.progress = 'Downloading model';
    await tester.pumpWidget(page());
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
