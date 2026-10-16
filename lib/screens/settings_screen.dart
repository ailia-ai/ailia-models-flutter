import 'package:flutter/material.dart';

import '../sdk_status.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.status});

  final SdkStatus status;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: status,
        builder: (context, _) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            ListTile(
              title: const Text('ailia SDK'),
              subtitle: SelectableText(status.version),
            ),
            ListTile(
              title: const Text('License expiration'),
              subtitle: SelectableText(status.expiry),
            ),
          ],
        ),
      ),
    );
  }
}
