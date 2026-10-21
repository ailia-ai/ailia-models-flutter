import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sdk_status.dart';
import 'settings_screen.dart';

/// Compact SDK/license details immediately to the left of Settings.
class SdkStatusActions extends StatelessWidget {
  const SdkStatusActions({super.key, this.status, this.onSettingsClosed});

  final SdkStatus? status;
  final VoidCallback? onSettingsClosed;

  @override
  Widget build(BuildContext context) {
    final sdkStatus = status ?? SdkStatus.instance;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListenableBuilder(
          listenable: sdkStatus,
          builder: (context, _) {
            final version = sdkStatus.version;
            final license = 'License expiration: ${sdkStatus.expiry}';
            return Tooltip(
              message: '$version\n$license',
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: math.min(
                    300,
                    MediaQuery.sizeOf(context).width * .4,
                  ),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      version,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                    Text(
                      license,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        IconButton(
          tooltip: 'Settings',
          icon: const Icon(Icons.settings),
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (context) => SettingsScreen(status: sdkStatus),
              ),
            );
            onSettingsClosed?.call();
          },
        ),
      ],
    );
  }
}
