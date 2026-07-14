// YOLOXで検出した物体をailia TrackerのByteTrackで追跡する

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui';

import 'package:ailia_tracker/ailia_tracker_model.dart';

import '../object_detection/yolox.dart';

/// One tracked object of the current frame together with the recent
/// trajectory of its box center. Coordinates are normalized (0..1).
class ByteTrackResult {
  final AiliaTrackerObject object;
  final List<Offset> trail;

  ByteTrackResult(this.object, this.trail);
}

/// Runs YOLOX object detection on each frame and feeds the detections
/// to ailia Tracker (ByteTrack) to assign stable IDs across frames.
class ObjectTrackingByteTrack {
  bool available = false;

  final ObjectDetectionYoloX _yolox = ObjectDetectionYoloX();
  final AiliaTrackerModel _tracker = AiliaTrackerModel();

  // ByteTrack keeps low-score detections for association, so the
  // detector runs with a low threshold and NMS disabled (iou = 1.0)
  // and the tracker settings do the filtering.
  static const double _detectionThreshold = 0.1;
  static const double _detectionIou = 1.0;

  /// Center-point history per tracking ID for the trajectory lines.
  final Map<int, List<Offset>> _trails = {};

  /// Frames since each ID was last seen, to drop stale trails.
  final Map<int, int> _lastSeen = {};
  int _frame = 0;

  static const int maxTrailLength = 50;
  static const int _staleTrailFrames = 60;

  List<String> get category => _yolox.category;

  void open(File yoloxOnnxFile, int envId) {
    if (available) {
      return;
    }

    _yolox.open(yoloxOnnxFile, envId);
    _tracker.create(
      scoreThreshold: 0.1,
      nmsThreshold: 0.7,
      trackThreshold: 0.5,
      trackBuffer: 30,
      matchThreshold: 0.8,
    );

    _trails.clear();
    _lastSeen.clear();
    _frame = 0;

    available = true;
  }

  void close() {
    if (!available) {
      return;
    }

    _tracker.close();
    _yolox.close();

    available = false;
  }

  List<ByteTrackResult> run(
    Uint8List data,
    int imageWidth,
    int imageHeight,
  ) {
    if (!available) {
      throw ("Model not opened");
    }

    final detections = _yolox.run(
      data,
      imageWidth,
      imageHeight,
      threshold: _detectionThreshold,
      iou: _detectionIou,
    );
    for (final d in detections) {
      _tracker.addTarget(AiliaTrackerTarget(
        category: d.category,
        prob: d.prob,
        x: d.x,
        y: d.y,
        w: d.w,
        h: d.h,
      ));
    }
    final objects = _tracker.compute();

    _frame++;
    final results = <ByteTrackResult>[];
    for (final obj in objects) {
      final trail = _trails.putIfAbsent(obj.id, () => []);
      trail.add(Offset(obj.x + obj.w / 2, obj.y + obj.h / 2));
      if (trail.length > maxTrailLength) {
        trail.removeAt(0);
      }
      _lastSeen[obj.id] = _frame;
      results.add(ByteTrackResult(obj, List.unmodifiable(trail)));
    }
    _lastSeen.removeWhere((id, seen) {
      final stale = _frame - seen > _staleTrailFrames;
      if (stale) {
        _trails.remove(id);
      }
      return stale;
    });

    return results;
  }
}
