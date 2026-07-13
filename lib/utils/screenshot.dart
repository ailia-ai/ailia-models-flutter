import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Wraps the whole app so its render tree can be captured as an image.
final GlobalKey screenshotBoundaryKey = GlobalKey();

/// Saves the current app content to [path] as a PNG.
Future<void> captureScreenshot(String path) async {
  final boundary = screenshotBoundaryKey.currentContext?.findRenderObject()
      as RenderRepaintBoundary?;
  if (boundary == null) {
    return;
  }
  final image = await boundary.toImage(pixelRatio: 2.0);
  final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
  if (byteData == null) {
    return;
  }
  await File(path).writeAsBytes(byteData.buffer.asUint8List());
  debugPrint('screenshot saved: $path');
}

/// Automation hook: when the AILIA_SCREENSHOT environment variable is set,
/// the app saves a screenshot to that path after AILIA_SCREENSHOT_DELAY
/// seconds (default 3). If AILIA_SCREENSHOT_INTERVAL is set, it keeps
/// re-capturing every that many seconds so screenshots can be taken after
/// manual interaction.
void scheduleAutoScreenshot() {
  final path = Platform.environment['AILIA_SCREENSHOT'];
  if (path == null || path.isEmpty) {
    return;
  }
  final delay =
      int.tryParse(Platform.environment['AILIA_SCREENSHOT_DELAY'] ?? '') ?? 3;
  final interval =
      int.tryParse(Platform.environment['AILIA_SCREENSHOT_INTERVAL'] ?? '');

  Timer(Duration(seconds: delay), () {
    captureScreenshot(path);
    if (interval != null && interval > 0) {
      Timer.periodic(Duration(seconds: interval), (_) {
        captureScreenshot(path);
      });
    }
  });
}
