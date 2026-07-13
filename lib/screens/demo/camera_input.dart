import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ailia/ailia_model.dart' show AiliaDetectorObject;
import 'package:camera/camera.dart';
// AudioFormat collides with the record package's; we only use the
// photo API.
import 'package:camera_macos/camera_macos.dart' hide AudioFormat;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

/// One camera frame as tightly packed RGB bytes.
class CameraFrame {
  CameraFrame(this.rgb, this.width, this.height);

  final Uint8List rgb;
  final int width;
  final int height;

  /// Converts to a ui.Image for display, using the raw pixel decoder
  /// (no PNG round trip).
  Future<ui.Image> toUiImage() {
    final rgba = Uint8List(width * height * 4);
    int o = 0;
    for (int i = 0; i < rgb.length; i += 3) {
      rgba[o++] = rgb[i];
      rgba[o++] = rgb[i + 1];
      rgba[o++] = rgb[i + 2];
      rgba[o++] = 255;
    }
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
        rgba, width, height, ui.PixelFormat.rgba8888, completer.complete);
    return completer.future;
  }

  img.Image toImage() {
    return img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgb.buffer,
      numChannels: 3,
    );
  }
}

/// Owns the platform camera used by the demos: the camera plugin on
/// Android / iOS / Windows / web, and camera_macos on macOS (where the
/// camera plugin has no implementation). Handles device enumeration
/// and selection, still capture for the multimodal demo and frame
/// grabbing for realtime inference. Notifies listeners whenever the
/// controller, device list, capture or displayed aspect changes.
class CameraInput extends ChangeNotifier {
  // Plugin camera state.
  CameraController? controller;
  List<CameraDescription> pluginCameras = [];
  int pluginCameraIndex = 0;

  // macOS camera state; the CameraMacOSView initializes the controller.
  CameraMacOSController? macController;
  List<CameraMacOSDevice> macDevices = [];
  String? macDeviceId;
  CameraImageData? _macLatestFrame;

  String? error;

  /// Aspect ratio of the frames actually processed, tracked so the
  /// preview box can match the realtime result frames.
  double trackedAspect = 4 / 3;

  /// Last still capture (multimodal demo); the preview freezes on it.
  Uint8List? capturedBytes;
  String? capturedPath;

  /// Whether this platform has a camera implementation at all. The
  /// camera plugin has no macOS/Linux implementation; macOS is covered
  /// by the camera_macos package instead.
  static bool get supported =>
      kIsWeb ||
      Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isWindows ||
      Platform.isMacOS;

  bool get usesMacCamera => !kIsWeb && Platform.isMacOS;

  /// Opens the camera. On macOS the CameraMacOSView initializes the
  /// controller itself, so this only refreshes the device list.
  Future<void> open() async {
    error = null;
    capturedBytes = null;
    capturedPath = null;
    notifyListeners();
    if (usesMacCamera) {
      _listMacDevices();
      return;
    }
    try {
      if (controller == null) {
        final cameras = await availableCameras();
        if (cameras.isEmpty) {
          throw Exception('No camera found');
        }
        // Prefer a normal camera over IR/depth cameras (Windows Hello).
        final camera = cameras.firstWhere(
          (c) => !c.name.toUpperCase().contains('IR'),
          orElse: () => cameras.first,
        );
        pluginCameras = cameras;
        pluginCameraIndex = cameras.indexOf(camera);
        final created = CameraController(
          camera,
          ResolutionPreset.medium,
          enableAudio: false,
        );
        await created.initialize();
        controller = created;
        trackedAspect = displayAspect(created);
      }
    } catch (e) {
      controller = null;
      error = 'Camera error: $e';
    }
    notifyListeners();
  }

  /// Releases the camera and clears any capture.
  Future<void> close() async {
    final plugin = controller;
    controller = null;
    final mac = macController;
    macController = null;
    _macLatestFrame = null;
    capturedBytes = null;
    capturedPath = null;
    notifyListeners();
    await plugin?.dispose();
    await mac?.destroy();
  }

  @override
  void dispose() {
    controller?.dispose();
    macController?.destroy();
    super.dispose();
  }

  Future<void> _listMacDevices() async {
    try {
      final devices = await CameraMacOSPlatform.instance
          .listDevices(deviceType: CameraMacOSDeviceType.video);
      macDevices = devices;
      notifyListeners();
    } catch (_) {
      // The default device keeps working without the selector.
    }
  }

  /// Called by the preview view when CameraMacOSView has initialized.
  void attachMacController(CameraMacOSController controller) {
    macController = controller;
    final size = controller.args.size;
    if (size.width > 0 && size.height > 0) {
      updateAspectFrom(size.width.toInt(), size.height.toInt());
    }
    notifyListeners();
  }

  void selectMacDevice(String deviceId) {
    macDeviceId = deviceId;
    _macLatestFrame = null;
    capturedBytes = null;
    capturedPath = null;
    notifyListeners();
  }

  Future<void> selectPluginCamera(int index) async {
    if (index == pluginCameraIndex && controller != null) {
      return;
    }
    capturedBytes = null;
    capturedPath = null;
    final old = controller;
    controller = null;
    notifyListeners();
    await old?.dispose();
    try {
      final created = CameraController(
        pluginCameras[index],
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await created.initialize();
      pluginCameraIndex = index;
      controller = created;
      trackedAspect = displayAspect(created);
    } catch (e) {
      error = 'Camera error: $e';
    }
    notifyListeners();
  }

  /// Captures a still image into [capturedBytes] / [capturedPath].
  /// Throws when the camera is not ready or the capture fails.
  Future<void> captureStill() async {
    capturedBytes = null;
    capturedPath = null;
    if (usesMacCamera) {
      final mac = macController;
      if (mac == null) {
        throw Exception(error ?? 'Camera is not ready.');
      }
      final shot = await mac.takePicture();
      final bytes = shot?.bytes;
      if (bytes == null) {
        throw Exception('Failed to capture image.');
      }
      capturedBytes = bytes;
      // Some demos (multimodal LLM) need a file path.
      final file =
          File('${Directory.systemTemp.path}/ailia_camera_capture.jpg');
      await file.writeAsBytes(bytes);
      capturedPath = file.path;
      notifyListeners();
      return;
    }
    final plugin = controller;
    if (plugin == null || !plugin.value.isInitialized) {
      throw Exception(error ?? 'Camera is not ready.');
    }
    final shot = await plugin.takePicture();
    final bytes = await shot.readAsBytes();
    capturedBytes = _mirrorCaptureToMatchPreview(bytes) ?? bytes;
    if (capturedBytes != bytes) {
      await File(shot.path).writeAsBytes(capturedBytes!);
    }
    capturedPath = shot.path;
    notifyListeners();
  }

  /// Returns to the live view after a frozen still capture.
  void clearCapture() {
    capturedBytes = null;
    capturedPath = null;
    notifyListeners();
  }

  /// camera_windows always mirrors the preview texture (selfie style)
  /// but captured photos are not mirrored, so a capture looks flipped
  /// compared to what the preview showed. Mirror the capture on Windows
  /// to match the preview. Returns null when no correction is needed.
  Uint8List? _mirrorCaptureToMatchPreview(Uint8List bytes) {
    if (!Platform.isWindows) {
      return null;
    }
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return null;
    }
    // Keep the display box in sync with the real capture aspect ratio
    // so the frozen frame is not letterboxed.
    updateAspectFrom(decoded.width, decoded.height);
    return img.encodeJpg(img.flipHorizontal(decoded));
  }

  CameraFrame _streamToFrame(CameraImageData data) {
    // camera_macos streams frames as ARGB, alpha first: the native side
    // converts its BGRA capture through NSBitmapImageRep, whose meshed
    // layout is A,R,G,B. Reading at the wrong offset shows up as a blue
    // or red tint because the constant 255 alpha lands on a color
    // channel.
    final out = Uint8List(data.width * data.height * 3);
    int o = 0;
    for (int y = 0; y < data.height; y++) {
      int i = y * data.bytesPerRow;
      for (int x = 0; x < data.width; x++) {
        out[o++] = data.bytes[i + 1];
        out[o++] = data.bytes[i + 2];
        out[o++] = data.bytes[i + 3];
        i += 4;
      }
    }
    return CameraFrame(out, data.width, data.height);
  }

  /// Grabs the current camera frame as tightly packed RGB bytes.
  Future<CameraFrame?> grabFrame() async {
    if (usesMacCamera) {
      final data = _macLatestFrame;
      if (data == null) {
        return null;
      }
      return _streamToFrame(data);
    }
    final plugin = controller;
    if (plugin == null || !plugin.value.isInitialized) {
      return null;
    }
    final shot = await plugin.takePicture();
    final bytes = await shot.readAsBytes();
    try {
      // Avoid piling up capture files while looping.
      await File(shot.path).delete();
    } catch (_) {}
    var decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return null;
    }
    // Android stores the capture rotation in EXIF, which decodeImage
    // does not apply. Bake it so the frame (and the aspect tracked from
    // it) is upright like the preview.
    decoded = img.bakeOrientation(decoded);
    if (Platform.isWindows) {
      // Match the preview, which camera_windows always mirrors.
      decoded = img.flipHorizontal(decoded);
    }
    // The photo aspect ratio can differ from the preview aspect ratio
    // (e.g. 4:3 photos with a 16:9 preview), which would letterbox the
    // displayed frames. Track the real frame aspect instead.
    updateAspectFrom(decoded.width, decoded.height);
    final rgbImage = decoded.convert(numChannels: 3);
    return CameraFrame(rgbImage.getBytes(order: img.ChannelOrder.rgb),
        rgbImage.width, rgbImage.height);
  }

  /// Starts the macOS frame stream feeding [grabFrame] during realtime
  /// inference.
  Future<void> startMacStream() async {
    _macLatestFrame = null;
    await macController?.startImageStream((data) {
      if (data != null) {
        _macLatestFrame = data;
        updateAspectFrom(data.width, data.height);
      }
    });
  }

  Future<void> stopMacStream() async {
    try {
      await macController?.stopImageStream();
    } catch (_) {
      // The controller may already be destroyed.
    }
  }

  void updateAspectFrom(int width, int height) {
    final aspect = width / height;
    if ((aspect - trackedAspect).abs() > 0.01) {
      trackedAspect = aspect;
      notifyListeners();
    }
  }

  /// Aspect ratio of the camera preview as displayed. The camera plugin
  /// reports the sensor aspect (landscape); on phones the preview is
  /// rotated to the device orientation, so the displayed box must use
  /// the inverse while the device is held in portrait. Uses the same
  /// orientation resolution as CameraPreview so the box always matches
  /// what the plugin renders.
  double displayAspect(CameraController controller) {
    final aspect = controller.value.aspectRatio;
    if (kIsWeb || !(Platform.isAndroid || Platform.isIOS)) {
      return aspect;
    }
    final orientation = controller.value.previewPauseOrientation ??
        controller.value.lockedCaptureOrientation ??
        controller.value.deviceOrientation;
    final landscape = orientation == DeviceOrientation.landscapeLeft ||
        orientation == DeviceOrientation.landscapeRight;
    return landscape ? aspect : 1 / aspect;
  }
}

/// The live camera preview box. Keeps its aspect ratio in sync with
/// what is actually displayed, freezes on a still capture (tap the
/// frozen image to return to the live view) and hosts the page's
/// result [overlay].
class CameraPreviewView extends StatelessWidget {
  const CameraPreviewView({
    super.key,
    required this.input,
    this.realtimeActive = false,
    this.overlay,
    this.onTapNormalized,
  });

  final CameraInput input;

  /// While realtime inference paints processed frames over the preview,
  /// the box keeps the aspect tracked from those frames (the photo
  /// aspect can differ from the live preview aspect).
  final bool realtimeActive;

  /// Painted over the live preview (realtime results, markers).
  final Widget? overlay;

  /// Tap handler in normalized (0..1) coordinates; used by SAM2 to
  /// move the segmentation point.
  final void Function(Offset normalized)? onTapNormalized;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: input,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    if (input.error != null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Text(input.error!,
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      );
    }
    Widget preview;
    if (input.usesMacCamera) {
      preview = CameraMacOSView(
        key: ValueKey(input.macDeviceId),
        deviceId: input.macDeviceId,
        cameraMode: CameraMacOSMode.photo,
        pictureFormat: PictureFormat.jpg,
        resolution: PictureResolution.medium,
        fit: BoxFit.fill,
        enableAudio: false,
        onCameraInizialized: input.attachMacController,
      );
    } else {
      final controller = input.controller;
      if (controller == null || !controller.value.isInitialized) {
        return const Padding(
          padding: EdgeInsets.all(16),
          child: CircularProgressIndicator(),
        );
      }
      preview = CameraPreview(controller);
    }
    // After a still capture (e.g. gemma3 multimodal), freeze the visible
    // preview on the captured frame while the camera keeps running
    // underneath. Tap the frozen image to return to the live view.
    final frozen = !realtimeActive && input.capturedBytes != null;
    Widget buildWithAspect(double aspect) => ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: AspectRatio(
            aspectRatio: aspect,
            child: LayoutBuilder(builder: (context, constraints) {
              final stack = Stack(
                fit: StackFit.expand,
                children: [
                  preview,
                  if (frozen)
                    GestureDetector(
                      onTap: input.clearCapture,
                      child: Image.memory(
                        input.capturedBytes!,
                        fit: BoxFit.contain,
                      ),
                    ),
                  if (!frozen && overlay != null) overlay!,
                ],
              );
              if (frozen || onTapNormalized == null) {
                return stack;
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
                child: stack,
              );
            }),
          ),
        );
    final controller = input.controller;
    if (input.usesMacCamera || controller == null) {
      return buildWithAspect(input.trackedAspect);
    }
    // Follow the controller so the box tracks camera switches and
    // device rotation.
    return ValueListenableBuilder<CameraValue>(
      valueListenable: controller,
      builder: (context, _, __) {
        final aspect = realtimeActive
            ? input.trackedAspect
            : input.displayAspect(controller);
        return buildWithAspect(aspect);
      },
    );
  }
}

/// Dropdown for choosing the camera device, covering both the plugin
/// cameras and the camera_macos device list.
class CameraDeviceSelector extends StatelessWidget {
  const CameraDeviceSelector({
    super.key,
    required this.input,
    this.enabled = true,
    this.onDeviceChanged,
  });

  final CameraInput input;

  /// Switching devices mid-run would restart the capture session, so
  /// the page disables the selector during realtime inference.
  final bool enabled;

  /// Lets the page clear result overlays that belong to the previous
  /// device.
  final VoidCallback? onDeviceChanged;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: input,
      builder: (context, _) =>
          input.usesMacCamera ? _buildMac(context) : _buildPlugin(context),
    );
  }

  Widget _buildMac(BuildContext context) {
    if (input.macDevices.isEmpty) {
      return const SizedBox.shrink();
    }
    return DropdownButton<String>(
      // null means the default device, which is the first one.
      value: input.macDeviceId ?? input.macDevices.first.deviceId,
      underline: const SizedBox.shrink(),
      isDense: true,
      style: Theme.of(context).textTheme.bodyMedium,
      onChanged: !enabled
          ? null
          : (value) {
              if (value == null) {
                return;
              }
              input.selectMacDevice(value);
              onDeviceChanged?.call();
            },
      items: [
        for (final device in input.macDevices)
          DropdownMenuItem<String>(
            value: device.deviceId,
            child: Text(device.localizedName ?? device.deviceId),
          ),
      ],
    );
  }

  Widget _buildPlugin(BuildContext context) {
    if (input.pluginCameras.isEmpty) {
      return const SizedBox.shrink();
    }
    return DropdownButton<int>(
      value: input.pluginCameraIndex,
      underline: const SizedBox.shrink(),
      isDense: true,
      style: Theme.of(context).textTheme.bodyMedium,
      onChanged: !enabled
          ? null
          : (value) {
              if (value == null) {
                return;
              }
              input.selectPluginCamera(value);
              onDeviceChanged?.call();
            },
      items: [
        for (int i = 0; i < input.pluginCameras.length; i++)
          DropdownMenuItem<int>(
            value: i,
            child: Text(_cameraDisplayName(input.pluginCameras[i])),
          ),
      ],
    );
  }
}

/// camera_windows appends the device instance path to the camera name
/// (e.g. "Integrated Camera <\\?\usb#vid_...>"), which is far too long
/// for the UI. Show only the friendly name part before the path.
String _cameraDisplayName(CameraDescription camera) {
  final name = camera.name;
  final pathStart = name.indexOf(' <');
  if (pathStart > 0) {
    return name.substring(0, pathStart);
  }
  return name;
}

/// Draws realtime inference results (bounding boxes, masks, labels)
/// on top of the live camera preview or a still image.
class CameraOverlayPainter extends CustomPainter {
  CameraOverlayPainter({
    required this.boxes,
    required this.categories,
    this.frameImage,
    this.overlayImage,
    this.label = '',
    this.marker,
  });

  final List<AiliaDetectorObject> boxes;
  final List<String> categories;

  /// The processed camera frame, drawn opaquely under the results so the
  /// displayed image matches what the model actually saw.
  final ui.Image? frameImage;
  final ui.Image? overlayImage;
  final String label;

  /// Marks the segmentation point (normalized 0..1) with a red dot.
  final Offset? marker;

  static const List<Color> _palette = [
    Colors.red,
    Colors.lime,
    Colors.blue,
    Colors.yellow,
    Colors.cyan,
    Colors.orange,
    Colors.purple,
    Colors.pink,
  ];

  @override
  void paint(Canvas canvas, ui.Size size) {
    final frame = frameImage;
    if (frame != null) {
      final src =
          Rect.fromLTWH(0, 0, frame.width.toDouble(), frame.height.toDouble());
      final dst = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawImageRect(frame, src, dst, Paint());
    }
    final overlay = overlayImage;
    if (overlay != null) {
      final src = Rect.fromLTWH(
          0, 0, overlay.width.toDouble(), overlay.height.toDouble());
      final dst = Rect.fromLTWH(0, 0, size.width, size.height);
      canvas.drawImageRect(
          overlay, src, dst, Paint()..color = Colors.white.withOpacity(0.7));
    }

    for (final box in boxes) {
      final color = _palette[box.category % _palette.length];
      // Detector coordinates are normalized to 0..1.
      final rect = Rect.fromLTWH(
        box.x * size.width,
        box.y * size.height,
        box.w * size.width,
        box.h * size.height,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = color,
      );
      final name = box.category < categories.length
          ? categories[box.category]
          : '${box.category}';
      _drawLabel(canvas, '$name ${(box.prob * 100).toStringAsFixed(0)}%',
          rect.left, rect.top, color);
    }

    if (label.isNotEmpty) {
      _drawLabel(canvas, label, 4, 4, Colors.black54);
    }

    final markerPos = marker;
    if (markerPos != null) {
      final center =
          Offset(markerPos.dx * size.width, markerPos.dy * size.height);
      canvas.drawCircle(
        center,
        7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.white,
      );
      canvas.drawCircle(center, 5, Paint()..color = Colors.red);
    }
  }

  void _drawLabel(Canvas canvas, String text, double x, double y, Color bg) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: const TextStyle(color: Colors.white, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final rect = Rect.fromLTWH(x, y, painter.width + 8, painter.height + 4);
    canvas.drawRect(rect, Paint()..color = bg.withOpacity(0.7));
    painter.paint(canvas, Offset(x + 4, y + 2));
  }

  @override
  bool shouldRepaint(CameraOverlayPainter oldDelegate) {
    return oldDelegate.boxes != boxes ||
        oldDelegate.frameImage != frameImage ||
        oldDelegate.overlayImage != overlayImage ||
        oldDelegate.label != label ||
        oldDelegate.marker != marker;
  }
}
