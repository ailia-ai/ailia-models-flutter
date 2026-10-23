import 'dart:async';

import 'package:ailia/ailia_model.dart';
import 'package:ailia/ailia.dart' show AILIA_ENVIRONMENT_TYPE_BLAS;
import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:flutter/material.dart';

import '../../large_language_model/qnn_model.dart';
import '../../large_language_model/qnn_runtime.dart';
import '../../license_error_dialog.dart';
import '../../utils/qnn_device.dart';
import '../../utils/qnn_env.dart';
import '../../utils/qnn_support.dart';
import '../../voice_agent/voice_agent_config.dart';
import '../../voice_agent/voice_agent_controller.dart';
import '../../voice_agent/voice_agent_camera.dart';
import 'voice_agent_camera_settings.dart';
import 'voice_agent_orb.dart';

export 'voice_agent_orb.dart' show VoiceAgentOrb;

class VoiceAgentDemoPage extends StatefulWidget {
  const VoiceAgentDemoPage({
    super.key,
    this.controller,
    this.environments,
    this.llmBackends,
    this.cameraDeviceLoader,
  });
  final VoiceAgentController? controller;
  final List<AiliaEnvironment>? environments;
  final List<String>? llmBackends;
  final Future<List<VoiceAgentCameraDevice>> Function()? cameraDeviceLoader;

  @override
  State<VoiceAgentDemoPage> createState() => _VoiceAgentDemoPageState();
}

class _VoiceAgentDemoPageState extends State<VoiceAgentDemoPage>
    with WidgetsBindingObserver {
  late final VoiceAgentController _agent;
  final _queries = TextEditingController(text: VoiceAgentConfig.defaultQueries);
  final _scroll = ScrollController();
  final _mtp = {'gemma4-e2b': true, 'gemma4-e4b': false};
  List<AiliaEnvironment> _environments = [];
  List<String> _backends = [];
  String _speechModel = 'whisper_medium';
  String _llmModel = 'gemma4-e2b';
  String _llmBackend = 'CPU';
  int _speechEnv = 0;
  int _voiceEnv = 0;
  bool _speechOutput = true;
  bool _testMode = false;
  bool _frontCamera = false;
  String? _cameraDeviceId;
  List<VoiceAgentCameraDevice> _cameraDevices = [];
  String? _setupError;
  String? _reportedError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _agent = widget.controller ?? VoiceAgentController();
    _agent.addListener(_changed);
    try {
      _environments = widget.environments ?? AiliaModel.getEnvironmentList();
      _backends = widget.llmBackends ?? AiliaLLMModel.getBackendList();
      final cpu = _environments
          .where((e) => !e.name.toUpperCase().contains('QNN'))
          .toList();
      _voiceEnv = cpuEnvironment(cpu);
      _speechEnv = speechQnnSoc(_speechModel) == null
          ? _voiceEnv
          : speechQnnEnvId;
      _llmBackend = llmBackends.firstWhere(
        isLlmQnnBackend,
        orElse: () => llmBackends.firstWhere(
          (b) => b == 'CPU',
          orElse: () => llmBackends.firstOrNull ?? 'CPU',
        ),
      );
    } catch (error) {
      _setupError = '$error';
    }
  }

  static int cpuEnvironment(List<AiliaEnvironment> environments) =>
      environments
          .where((e) => e.type == AILIA_ENVIRONMENT_TYPE_BLAS)
          .firstOrNull
          ?.id ??
      environments
          .where((e) => e.name.toUpperCase().contains('CPU'))
          .firstOrNull
          ?.id ??
      environments.firstOrNull?.id ??
      0;

  List<String> get llmBackends {
    final soc = availableWindowsQnnSoc();
    final qnn = soc != null && (_llmModel == 'gemma4-e2b' || soc == 'sc8380xp');
    return _backends.where((b) => !isLlmQnnBackend(b) || qnn).toList();
  }

  List<AiliaEnvironment> get speechEnvironments => [
    ..._environments.where((e) => !e.name.toUpperCase().contains('QNN')),
    if (speechQnnSoc(_speechModel) != null) speechQnnEnvironment,
  ];
  List<AiliaEnvironment> get voiceEnvironments => _environments
      .where((e) => isSdkQnnEnvironmentSelectable(e.name, qnnSocName))
      .toList();

  void _changed() {
    if (!mounted) return;
    setState(() {});
    if (_agent.error != null && _agent.error != _reportedError) {
      _reportedError = _agent.error;
      showAiliaLicenseError(_agent.error!);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(_agent.stop());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _agent.removeListener(_changed);
    if (widget.controller == null) {
      _agent.dispose();
    } else {
      unawaited(_agent.stop());
    }
    _queries.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _start() {
    FocusManager.instance.primaryFocus?.unfocus();
    _reportedError = null;
    unawaited(
      _agent.start(
        VoiceAgentConfig(
          speechModel: _speechModel,
          llmModel: _llmModel,
          speechEnvId: _speechEnv,
          voiceEnvId: _voiceEnv,
          llmBackend: _llmBackend,
          mtp: _mtp[_llmModel]! && mtpAvailable(_llmModel, _llmBackend),
          speechOutput: _speechOutput,
          testMode: _testMode,
          frontCamera: _frontCamera,
          cameraDeviceId: _cameraDeviceId,
          queries: _queries.text
              .split('\n')
              .map((q) => q.trim())
              .where((q) => q.isNotEmpty)
              .toList(),
        ),
      ),
    );
  }

  Widget _select<T>(
    String label,
    T value,
    Map<T, String> choices,
    ValueChanged<T> change, {
    bool enabled = true,
  }) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: DropdownButtonFormField<T>(
      key: ValueKey('$label:$value'),
      initialValue: choices.containsKey(value) ? value : null,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: choices.entries
          .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
          .toList(),
      onChanged: enabled
          ? (v) {
              if (v != null) setState(() => change(v));
            }
          : null,
    ),
  );
  Widget _env(
    String label,
    int value,
    List<AiliaEnvironment> environments,
    ValueChanged<int> change, {
    bool enabled = true,
  }) => _select(
    label,
    value,
    {for (final env in environments) env.id: env.name},
    change,
    enabled: enabled,
  );

  Widget _setup() => Scaffold(
    appBar: AppBar(title: const Text('Voice Agent')),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Whisper → Gemma 4 → GPT-SoVITS V2-Pro Distill Base'),
            const SizedBox(height: 16),
            _select(
              '音声認識モデル',
              _speechModel,
              const {
                'whisper_medium': 'Whisper Medium',
                'whisper_large_v3_turbo': 'Whisper Large V3 Turbo',
              },
              (v) {
                _speechModel = v;
                if (!speechEnvironments.any((e) => e.id == _speechEnv)) {
                  _speechEnv = cpuEnvironment(speechEnvironments);
                }
              },
            ),
            _env(
              '音声認識バックエンド',
              _speechEnv,
              speechEnvironments,
              (v) => _speechEnv = v,
            ),
            _select(
              '応答モデル',
              _llmModel,
              const {'gemma4-e2b': 'Gemma 4 E2B', 'gemma4-e4b': 'Gemma 4 E4B'},
              (v) {
                _llmModel = v;
                if (!llmBackends.contains(_llmBackend)) {
                  _llmBackend = llmBackends.firstWhere(
                    (b) => b == 'CPU',
                    orElse: () => llmBackends.first,
                  );
                }
              },
            ),
            _select('応答バックエンド', _llmBackend, {
              for (final b in llmBackends) b: b,
            }, (v) => _llmBackend = v),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('MTP'),
              subtitle: const Text('対応モデルで3トークンずつ先読みします'),
              value: _mtp[_llmModel]! && mtpAvailable(_llmModel, _llmBackend),
              onChanged: mtpAvailable(_llmModel, _llmBackend)
                  ? (v) => setState(() => _mtp[_llmModel] = v)
                  : null,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('応答の音声合成'),
              value: _speechOutput,
              onChanged: (v) => setState(() => _speechOutput = v),
            ),
            _env(
              '音声合成バックエンド',
              _voiceEnv,
              voiceEnvironments,
              (v) => _voiceEnv = v,
              enabled: _speechOutput || _testMode,
            ),
            VoiceAgentCameraSettings(
              front: _frontCamera,
              deviceId: _cameraDeviceId,
              onFrontChanged: (value) => setState(() => _frontCamera = value),
              onDeviceChanged: (value) =>
                  setState(() => _cameraDeviceId = value),
              initialDevices: _cameraDevices,
              loadDevices: () async {
                final devices =
                    await (widget.cameraDeviceLoader ??
                        voiceAgentCameraDevices)();
                _cameraDevices = devices;
                return devices;
              },
            ),
            const SizedBox(height: 12),
            const Text(
              '利用可能なツール',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.thermostat),
              title: Text('set_air_conditioner_temperature'),
              subtitle: Text('「エアコンを20度にして」\nサンプル内の設定温度を変更します。'),
            ),
            const ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.photo_camera),
              title: Text('take_photo'),
              subtitle: Text('「写真を撮影してください」\n撮影した写真について続けて質問できます。'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('テスト：GPT-SoVITS合成音声'),
              subtitle: const Text('マイクを使わず、1行に1件のクエリを音声認識します'),
              value: _testMode,
              onChanged: (v) => setState(() => _testMode = v),
            ),
            if (_testMode)
              TextField(
                controller: _queries,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: 'テストクエリ',
                  border: OutlineInputBorder(),
                ),
              ),
            if (_setupError ?? _agent.error case final error?)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  error,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed:
                  _setupError == null &&
                      _environments.isNotEmpty &&
                      llmBackends.isNotEmpty
                  ? _start
                  : null,
              icon: const Icon(Icons.mic),
              label: const Text('開始'),
            ),
          ],
        ),
      ),
    ),
  );

  Widget _call() => Scaffold(
    backgroundColor: Colors.black,
    body: SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                if (_agent.temperature != null)
                  Text(
                    'エアコン ${_agent.temperature} ℃',
                    style: const TextStyle(color: Colors.white),
                  ),
                const Spacer(),
                if (_agent.photo != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      _agent.photo!,
                      width: 72,
                      height: 72,
                      fit: BoxFit.cover,
                    ),
                  ),
                IconButton(
                  tooltip: '対話を終了',
                  onPressed: () => unawaited(_agent.stop()),
                  icon: const Icon(Icons.close, color: Colors.white),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 3,
            child: SizedBox.expand(
              child: VoiceAgentOrb(
                audio: _agent.waveform,
                state: _agent.state,
                stateRevision: _agent.stateRevision,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              _agent.state.label,
              style: const TextStyle(color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ),
          if (_agent.progress.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                children: [
                  LinearProgressIndicator(value: _agent.downloadProgress),
                  const SizedBox(height: 8),
                  Text(
                    _agent.progress,
                    style: const TextStyle(color: Colors.white60),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
          Expanded(
            flex: 2,
            child: SingleChildScrollView(
              controller: _scroll,
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_agent.input.isNotEmpty)
                    Text(
                      _agent.input,
                      style: const TextStyle(
                        color: Colors.white60,
                        fontSize: 16,
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    _agent.output,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: IconButton.filledTonal(
              tooltip: _agent.state == VoiceAgentState.listening
                  ? '送信'
                  : '応答を中断',
              iconSize: 30,
              onPressed: _agent.state == VoiceAgentState.listening
                  ? _agent.canSend
                        ? () => unawaited(_agent.send())
                        : null
                  : _agent.state.interruptible
                  ? () => unawaited(_agent.interrupt())
                  : null,
              icon: Icon(
                _agent.state == VoiceAgentState.listening
                    ? Icons.arrow_upward
                    : Icons.stop,
              ),
            ),
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_agent.active,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop && _agent.active) unawaited(_agent.stop());
    },
    child: _agent.active ? _call() : _setup(),
  );
}
