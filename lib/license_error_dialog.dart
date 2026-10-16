import 'dart:async';

import 'package:flutter/material.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();
bool _dialogVisible = false;

// The SDK wrappers throw messages such as "ailiaCreate failed -20".
// Workers forward the same message as a string.
bool isAiliaLicenseError(Object error) => RegExp(
  r'\b(?:ailia\w+|SetPromptJson|GetResponseJson(?:Size)?)\b[^\r\n]*?'
  r'\b(?:failed|status|error|returned)\s*:?\s*(-20|-21|-22)\b',
  caseSensitive: false,
).hasMatch(error.toString());

void showAiliaLicenseError(Object error) {
  final context = appNavigatorKey.currentContext;
  if (context == null || _dialogVisible || !isAiliaLicenseError(error)) return;
  _dialogVisible = true;
  unawaited(
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('ライセンスエラー'),
        content: const Text('ライセンスファイルが見つかりません'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    ).whenComplete(() => _dialogVisible = false),
  );
}
