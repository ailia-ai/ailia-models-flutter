import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../sdk_status.dart';
import 'settings_screen.dart';

/// Compact SDK/license details immediately to the left of Settings.
class SdkStatusActions extends StatefulWidget {
  const SdkStatusActions({super.key, this.status});

  final SdkStatus? status;

  @override
  State<SdkStatusActions> createState() => _SdkStatusActionsState();
}

class _SdkStatusActionsState extends State<SdkStatusActions>
    with WidgetsBindingObserver {
  SdkStatus get _status => widget.status ?? SdkStatus.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_status.refresh());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_status.refresh());
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ListenableBuilder(
          listenable: _status,
          builder: (context, _) {
            final version = 'ailia SDK: ${_status.version ?? '取得できません'}';
            final license = 'ライセンス期日: ${_status.license?.label ?? '確認中…'}';
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
                builder: (context) => SettingsScreen(status: _status),
              ),
            );
            if (mounted) await _status.refresh();
          },
        ),
      ],
    );
  }
}
