import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:camera_macos/camera_macos.dart' as mac;
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

class VoiceAgentCameraDevice {
  const VoiceAgentCameraDevice(this.id, this.label);
  final String id;
  final String label;
}

/// Enumerating macOS cameras can request permission. Invoke only from the
/// settings button or when a requested photo needs a specific camera.
Future<List<VoiceAgentCameraDevice>> voiceAgentCameraDevices() async {
  if (Platform.isMacOS) {
    final devices = await mac.CameraMacOSPlatform.instance.listDevices(
      deviceType: mac.CameraMacOSDeviceType.video,
    );
    return [
      for (final device in devices)
        VoiceAgentCameraDevice(
          device.deviceId,
          device.localizedName ?? device.deviceId,
        ),
    ];
  }
  return [
    for (final camera in await availableCameras())
      VoiceAgentCameraDevice(
        camera.name,
        '${camera.name} (${switch (camera.lensDirection) {
          CameraLensDirection.front => 'インカメラ',
          CameraLensDirection.back => 'アウトカメラ',
          CameraLensDirection.external => '外部カメラ',
        }})',
      ),
  ];
}

CameraDescription selectVoiceAgentCamera(
  List<CameraDescription> cameras, {
  required bool front,
  String? deviceId,
  bool requireFacing = true,
}) {
  if (cameras.isEmpty) throw StateError('カメラが見つかりません');
  if (deviceId != null) {
    return cameras.firstWhere(
      (c) => c.name == deviceId,
      orElse: () => throw StateError('選択したカメラが見つかりません。カメラ設定を確認してください'),
    );
  }
  final facing = front ? CameraLensDirection.front : CameraLensDirection.back;
  return cameras.firstWhere(
    (c) => c.lensDirection == facing,
    orElse: () => requireFacing
        ? throw StateError(front ? 'インカメラがありません' : 'アウトカメラがありません')
        : cameras.first,
  );
}

/// No preview or audio session. Open only for a requested take_photo call,
/// give auto-exposure a bounded settling interval, and always release capture.
class VoiceAgentCamera {
  Future<Uint8List> capture({
    required bool front,
    String? deviceId,
    required void Function() checkActive,
  }) async {
    Uint8List bytes;
    if (Platform.isMacOS) {
      final camera = mac.CameraMacOSPlatform.instance;
      if (deviceId != null) {
        final devices = await camera.listDevices(
          deviceType: mac.CameraMacOSDeviceType.video,
        );
        checkActive();
        if (!devices.any((d) => d.deviceId == deviceId)) {
          throw StateError('選択したカメラが見つかりません。カメラ設定を確認してください');
        }
      }
      try {
        await camera.initialize(
          deviceId: deviceId,
          enableAudio: false,
          cameraMacOSMode: mac.CameraMacOSMode.photo,
          pictureFormat: mac.PictureFormat.jpg,
          isVideoMirrored: false,
        );
        checkActive();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        checkActive();
        final photo = await camera.takePicture();
        if (photo == null) throw StateError('写真を撮影できませんでした');
        bytes = photo.bytes ?? await File(photo.url!).readAsBytes();
        if (photo.url != null) {
          final file = File(photo.url!);
          if (await file.exists()) await file.delete();
        }
      } finally {
        await camera.destroy();
      }
    } else {
      final cameras = await availableCameras();
      checkActive();
      final description = selectVoiceAgentCamera(
        cameras,
        front: front,
        deviceId: deviceId,
        requireFacing: Platform.isAndroid || Platform.isIOS,
      );
      final camera = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
      );
      try {
        await camera.initialize();
        checkActive();
        await Future<void>.delayed(const Duration(milliseconds: 800));
        checkActive();
        final photo = await camera.takePicture();
        try {
          bytes = await photo.readAsBytes();
        } finally {
          final file = File(photo.path);
          if (await file.exists()) await file.delete();
        }
      } finally {
        await camera.dispose();
      }
    }
    checkActive();
    final bounded = await compute(voiceAgentPhotoJpeg, bytes);
    checkActive();
    return bounded;
  }
}

Uint8List voiceAgentPhotoJpeg(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) throw const FormatException('写真を読み込めませんでした');
  var image = img.bakeOrientation(decoded);
  if (max(image.width, image.height) > 512) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? 512 : null,
      height: image.height > image.width ? 512 : null,
    );
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 85));
}

String voiceAgentPhotoData(Uint8List bytes) => base64Encode(bytes);
