import 'dart:io';

import 'package:flutter/material.dart';

import '../../voice_agent/voice_agent_camera.dart';

class VoiceAgentCameraSettings extends StatefulWidget {
  const VoiceAgentCameraSettings({
    super.key,
    required this.front,
    required this.deviceId,
    required this.onFrontChanged,
    required this.onDeviceChanged,
    this.loadDevices,
    this.desktop,
    this.initialDevices = const [],
  });
  final bool front;
  final String? deviceId;
  final ValueChanged<bool> onFrontChanged;
  final ValueChanged<String?> onDeviceChanged;
  final Future<List<VoiceAgentCameraDevice>> Function()? loadDevices;
  final bool? desktop;
  final List<VoiceAgentCameraDevice> initialDevices;

  @override
  State<VoiceAgentCameraSettings> createState() =>
      _VoiceAgentCameraSettingsState();
}

class _VoiceAgentCameraSettingsState extends State<VoiceAgentCameraSettings> {
  List<VoiceAgentCameraDevice> _devices = [];
  bool _loading = false;
  String? _error;
  bool get _desktop =>
      widget.desktop ??
      (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    _devices = List.of(widget.initialDevices);
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final devices = await (widget.loadDevices ?? voiceAgentCameraDevices)();
      if (mounted) {
        setState(() {
          _devices = devices;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = '$error';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      if (!_desktop)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: DropdownButtonFormField<bool>(
            key: ValueKey('カメラ:${widget.front}'),
            initialValue: widget.front,
            decoration: const InputDecoration(
              labelText: 'カメラ',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(value: false, child: Text('アウトカメラ')),
              DropdownMenuItem(value: true, child: Text('インカメラ')),
            ],
            onChanged: widget.deviceId == null
                ? (value) {
                    if (value != null) widget.onFrontChanged(value);
                  }
                : null,
          ),
        ),
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: DropdownButtonFormField<String>(
          key: ValueKey('撮影デバイス:${widget.deviceId ?? ''}'),
          initialValue: widget.deviceId ?? '',
          isExpanded: true,
          decoration: const InputDecoration(
            labelText: '撮影デバイス',
            border: OutlineInputBorder(),
          ),
          items: [
            DropdownMenuItem(
              value: '',
              child: Text(_desktop ? 'システムの既定カメラ' : '前後カメラ設定に従う'),
            ),
            for (final device in _devices)
              DropdownMenuItem(
                value: device.id,
                child: Text(device.label, overflow: TextOverflow.ellipsis),
              ),
            if (widget.deviceId != null &&
                !_devices.any((d) => d.id == widget.deviceId))
              DropdownMenuItem(
                value: widget.deviceId,
                child: const Text('選択したカメラ（未接続・未確認）'),
              ),
          ],
          onChanged: _loading
              ? null
              : (value) => widget.onDeviceChanged(value == '' ? null : value),
        ),
      ),
      Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _loading ? null : _refresh,
          icon: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.refresh),
          label: const Text('カメラ一覧を取得'),
        ),
      ),
      const Text(
        '一覧の取得時にカメラの権限確認が表示される場合があります。',
        style: TextStyle(fontSize: 12),
      ),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ],
  );
}
