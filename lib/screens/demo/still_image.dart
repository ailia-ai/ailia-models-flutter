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

/// Shows a still input or result image at up to 45% of the screen
/// height, always preserving the image aspect ratio (on narrow screens
/// the box shrinks to the available width instead of distorting).
class StillImageBox extends StatelessWidget {
  const StillImageBox({
    super.key,
    required this.image,
    this.overlay,
    this.onTapNormalized,
  });

  final ui.Image image;

  /// Painted over the image (detection boxes, markers).
  final Widget? overlay;

  /// Tap handler in normalized (0..1) coordinates; used by SAM2 to
  /// move the segmentation point.
  final void Function(Offset normalized)? onTapNormalized;

  @override
  Widget build(BuildContext context) {
    final aspect = image.width / image.height;
    final maxHeight = MediaQuery.of(context).size.height * 0.45;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      constraints: BoxConstraints(
        maxHeight: maxHeight,
        maxWidth: maxHeight * aspect,
      ),
      child: AspectRatio(
        aspectRatio: aspect,
        child: LayoutBuilder(builder: (context, constraints) {
          Widget content = Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(painter: StillImagePainter(image: image)),
              if (overlay != null) overlay!,
            ],
          );
          if (onTapNormalized == null) {
            return content;
          }
          return GestureDetector(
            onTapDown: (details) {
              onTapNormalized!(Offset(
                (details.localPosition.dx / constraints.maxWidth)
                    .clamp(0.0, 1.0),
                (details.localPosition.dy / constraints.maxHeight)
                    .clamp(0.0, 1.0),
              ));
            },
            child: content,
          );
        }),
      ),
    );
  }
}
