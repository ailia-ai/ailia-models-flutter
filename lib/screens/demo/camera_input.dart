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

  // Latest frame of the plugin video stream (Android/iOS realtime).
  CameraImage? _pluginLatestFrame;
  bool _pluginStreamActive = false;

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

  /// Whether realtime frames come from the video stream instead of
  /// per-frame still captures. Still captures fire the shutter sound on
  /// every frame (mandatory in some regions), so mobile uses the video
  /// stream; camera_windows does not implement image streaming.
  bool get _usesPluginStream =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Streamed pixel format: iOS delivers BGRA, Android YUV420.
  static ImageFormatGroup get _streamImageFormat {
    if (!kIsWeb && Platform.isIOS) {
      return ImageFormatGroup.bgra8888;
    }
    return ImageFormatGroup.yuv420;
  }

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
          imageFormatGroup: _streamImageFormat,
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
        imageFormatGroup: _streamImageFormat,
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
    if (_pluginStreamActive) {
      final image = _pluginLatestFrame;
      if (image == null) {
        return null;
      }
      return _pluginStreamToFrame(plugin, image);
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

  /// Converts a streamed plugin frame (BGRA on iOS, YUV420 on Android)
  /// into an upright RGB frame.
  CameraFrame? _pluginStreamToFrame(
      CameraController controller, CameraImage image) {
    img.Image? rgb;
    if (image.format.group == ImageFormatGroup.bgra8888) {
      rgb = _bgraToImage(image);
    } else if (image.format.group == ImageFormatGroup.yuv420) {
      rgb = _yuv420ToImage(image);
    }
    if (rgb == null) {
      return null;
    }
    final rotation = _streamRotationDegrees(controller);
    if (rotation != 0) {
      rgb = img.copyRotate(rgb, angle: rotation);
    }
    if (Platform.isAndroid &&
        controller.description.lensDirection == CameraLensDirection.front) {
      // The Android preview mirrors front cameras (selfie style) while
      // the analysis stream is not mirrored; flip the frames so the
      // realtime results match the preview. iOS mirrors the front video
      // output natively, so its frames already match.
      rgb = img.flipHorizontal(rgb);
    }
    updateAspectFrom(rgb.width, rgb.height);
    return CameraFrame(
        rgb.getBytes(order: img.ChannelOrder.rgb), rgb.width, rgb.height);
  }

  /// Clockwise rotation that brings a streamed frame upright. iOS
  /// rotates the video output to the device orientation on the native
  /// side; Android streams in sensor orientation.
  int _streamRotationDegrees(CameraController controller) {
    if (!Platform.isAndroid) {
      return 0;
    }
    final sensor = controller.description.sensorOrientation;
    int device;
    switch (controller.value.deviceOrientation) {
      case DeviceOrientation.portraitUp:
        device = 0;
      case DeviceOrientation.landscapeLeft:
        device = 90;
      case DeviceOrientation.portraitDown:
        device = 180;
      case DeviceOrientation.landscapeRight:
        device = 270;
    }
    if (controller.description.lensDirection == CameraLensDirection.front) {
      return (sensor + device) % 360;
    }
    return (sensor - device + 360) % 360;
  }

  img.Image _bgraToImage(CameraImage image) {
    final plane = image.planes[0];
    final w = image.width;
    final h = image.height;
    final out = Uint8List(w * h * 3);
    int o = 0;
    for (int y = 0; y < h; y++) {
      int i = y * plane.bytesPerRow;
      for (int x = 0; x < w; x++) {
        out[o++] = plane.bytes[i + 2];
        out[o++] = plane.bytes[i + 1];
        out[o++] = plane.bytes[i];
        i += 4;
      }
    }
    return img.Image.fromBytes(
        width: w, height: h, bytes: out.buffer, numChannels: 3);
  }

  img.Image _yuv420ToImage(CameraImage image) {
    final w = image.width;
    final h = image.height;
    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;
    final out = Uint8List(w * h * 3);
    int o = 0;
    for (int y = 0; y < h; y++) {
      final yRow = y * yPlane.bytesPerRow;
      final uvRow = (y >> 1) * uPlane.bytesPerRow;
      for (int x = 0; x < w; x++) {
        final yp = yPlane.bytes[yRow + x];
        final uvIndex = uvRow + (x >> 1) * uvPixelStride;
        final up = uPlane.bytes[uvIndex] - 128;
        final vp = vPlane.bytes[uvIndex] - 128;
        // BT.601 YUV to RGB in fixed point.
        final r = yp + ((1436 * vp) >> 10);
        final g = yp - ((352 * up) >> 10) - ((731 * vp) >> 10);
        final b = yp + ((1815 * up) >> 10);
        out[o++] = r < 0 ? 0 : (r > 255 ? 255 : r);
        out[o++] = g < 0 ? 0 : (g > 255 ? 255 : g);
        out[o++] = b < 0 ? 0 : (b > 255 ? 255 : b);
      }
    }
    return img.Image.fromBytes(
        width: w, height: h, bytes: out.buffer, numChannels: 3);
  }

  /// Starts streaming frames into [grabFrame] for realtime inference.
  /// Uses the video stream where available (no per-frame shutter
  /// sound); on other platforms [grabFrame] falls back to still
  /// captures.
  Future<void> startFrameStream() async {
    if (usesMacCamera) {
      _macLatestFrame = null;
      await macController?.startImageStream((data) {
        if (data != null) {
          _macLatestFrame = data;
          updateAspectFrom(data.width, data.height);
        }
      });
      return;
    }
    if (_usesPluginStream && controller != null) {
      _pluginLatestFrame = null;
      await controller!.startImageStream((image) {
        _pluginLatestFrame = image;
      });
      _pluginStreamActive = true;
    }
  }

  Future<void> stopFrameStream() async {
    if (usesMacCamera) {
      try {
        await macController?.stopImageStream();
      } catch (_) {
        // The controller may already be destroyed.
      }
      return;
    }
    if (_pluginStreamActive) {
      _pluginStreamActive = false;
      _pluginLatestFrame = null;
      try {
        await controller?.stopImageStream();
      } catch (_) {
        // The controller may already be disposed.
      }
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
    this.cornerLabel,
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

  /// Short status text (e.g. the FPS) shown at the top right corner of
  /// the preview.
  final String? cornerLabel;

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
                  if (!frozen && cornerLabel != null)
                    Positioned(
                      top: 4,
                      right: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black54,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          cornerLabel!,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 12),
                        ),
                      ),
                    ),
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
            child: Text(_cameraDisplayName(input.pluginCameras, i)),
          ),
      ],
    );
  }
}

/// The camera names the plugin reports are not fit for the UI on every
/// platform: camera_windows appends the device instance path to the
/// name ("Integrated Camera <\\?\usb#vid_...>"), iOS reports the
/// AVCaptureDevice unique ID
/// ("com.apple.avfoundation.avcapturedevice.built-in_video:0") and
/// Android reports the bare camera id ("0"). Show the friendly part of
/// the Windows name, and name mobile cameras by their lens direction.
String _cameraDisplayName(List<CameraDescription> cameras, int index) {
  final camera = cameras[index];
  final name = camera.name;
  final pathStart = name.indexOf(' <');
  if (pathStart > 0) {
    return name.substring(0, pathStart);
  }
  if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
    String label;
    switch (camera.lensDirection) {
      case CameraLensDirection.back:
        label = 'Back Camera';
      case CameraLensDirection.front:
        label = 'Front Camera';
      case CameraLensDirection.external:
        label = 'External Camera';
    }
    // Number cameras that face the same way apart.
    final sameDirection = [
      for (final c in cameras)
        if (c.lensDirection == camera.lensDirection) c
    ];
    if (sameDirection.length > 1) {
      label = '$label ${sameDirection.indexOf(camera) + 1}';
    }
    return label;
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
