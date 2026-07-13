import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Draws a ui.Image stretched over the paint area. Shared by the demo
/// pages that display a still input or result image.
class StillImagePainter extends CustomPainter {
  StillImagePainter({required this.image});

  final ui.Image image;

  @override
  void paint(Canvas canvas, ui.Size size) {
    final src =
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    final dst = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawImageRect(image, src, dst, Paint());
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) {
    return false;
  }
}

/// Sizes an image box to 45% of the screen height, preserving the
/// image aspect ratio. Returns null when there is no image.
Size? stillImageBoxSize(BuildContext context, ui.Image? image) {
  if (image == null) {
    return null;
  }
  final screenHeight = MediaQuery.of(context).size.height;
  final height = screenHeight * 0.45;
  return Size(height * image.width / image.height, height);
}
