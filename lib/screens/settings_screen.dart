import 'package:flutter/material.dart';

import '../large_language_model/qnn_model.dart';
import '../sdk_status.dart';

/// App settings. Debug options are kept in memory and reset on restart.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.status});

  final SdkStatus status;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        title: const Text('Settings'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('ailia SDK'),
            subtitle: SelectableText(widget.status.version),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('License expiration'),
            subtitle: SelectableText(widget.status.expiry),
          ),
          const SizedBox(height: 16),
          Text('Debug options', style: textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Not saved; reset to the defaults when the app restarts.',
            style: textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          const ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('QNN model format (.qnn)'),
            subtitle: Text(
              'Gemma 4 context binaries loaded on the HTP (NPU) backend.\n'
              'v1.5.1: gemma4-<model>-<soc>-<precision>-mtp.qnn (MTP capable)\n'
              'v1.5.0: gemma4-<model>-<soc>.qnn (older format, no MTP)',
            ),
            isThreeLine: true,
          ),
          SegmentedButton<QnnModelFormat>(
            segments: [
              for (final format in QnnModelFormat.values.reversed)
                ButtonSegment(value: format, label: Text(format.label)),
            ],
            selected: {qnnModelFormat},
            onSelectionChanged: (selection) => setState(() {
              qnnModelFormat = selection.first;
            }),
          ),
        ],
      ),
    );
  }
}
