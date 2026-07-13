import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:wav/wav.dart';

import 'demo_session.dart';

/// Scrolling peak-amplitude waveform shared by the microphone input
/// and TTS playback: one block per ~10ms of audio, most recent last.
class WaveformController extends ChangeNotifier {
  /// Number of amplitude blocks kept in the display.
  static const int blockCount = 300;

  final List<double> blocks = [];
  Timer? _playbackTimer;
  bool _disposed = false;

  /// Peak amplitude per ~10ms block, the unit of the waveform display.
  static List<double> peakBlocks(List<double> samples, int sampleRate) {
    final blockSize = sampleRate ~/ 100;
    final blocks = <double>[];
    for (int i = 0; i + blockSize <= samples.length; i += blockSize) {
      double peak = 0;
      for (int j = i; j < i + blockSize; j++) {
        peak = math.max(peak, samples[j].abs());
      }
      blocks.add(peak);
    }
    return blocks;
  }

  /// Appends blocks, keeping the last [blockCount] entries.
  void push(List<double> newBlocks) {
    blocks.addAll(newBlocks);
    if (blocks.length > blockCount) {
      blocks.removeRange(0, blocks.length - blockCount);
    }
    notifyListeners();
  }

  void clear() {
    blocks.clear();
    notifyListeners();
  }

  /// Streams the waveform of a synthesized wav file into the display,
  /// following the playback position in time.
  Future<void> playFromWav(String wavPath) async {
    final wav = await Wav.readFile(wavPath);
    if (wav.channels.isEmpty) {
      return;
    }
    final wavBlocks = peakBlocks(wav.channels[0], wav.samplesPerSecond);
    if (wavBlocks.isEmpty || _disposed) {
      return;
    }

    _playbackTimer?.cancel();
    clear();

    final startMs = DateTime.now().millisecondsSinceEpoch;
    int nextBlock = 0;
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 33), (timer) {
      if (_disposed) {
        timer.cancel();
        return;
      }
      final elapsedMs = DateTime.now().millisecondsSinceEpoch - startMs;
      int target = math.min(elapsedMs ~/ 10, wavBlocks.length);
      if (target > nextBlock) {
        push(wavBlocks.sublist(nextBlock, target));
        nextBlock = target;
      }
      if (nextBlock >= wavBlocks.length) {
        timer.cancel();
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _playbackTimer?.cancel();
    super.dispose();
  }
}

/// The waveform panel: an optional REC indicator with elapsed time and
/// the scrolling waveform. Hidden while empty unless [showWhenEmpty]
/// (the microphone input keeps the empty box visible).
class WaveformView extends StatelessWidget {
  const WaveformView({
    super.key,
    required this.controller,
    this.recording = false,
    this.recStart,
    this.showWhenEmpty = false,
  });

  final WaveformController controller;
  final bool recording;

  /// Recording start time shown next to the REC indicator.
  final DateTime? recStart;

  final bool showWhenEmpty;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        if (!showWhenEmpty && controller.blocks.isEmpty) {
          return const SizedBox.shrink();
        }
        String recTime = '';
        if (recording && recStart != null) {
          final elapsed = DateTime.now().difference(recStart!);
          final minutes = (elapsed.inSeconds ~/ 60).toString().padLeft(2, '0');
          final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
          recTime = "$minutes:$seconds";
        }
        return DemoPanel(
          child: Column(
            children: [
              if (recording)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.fiber_manual_record,
                          color: Colors.red, size: 14),
                      const SizedBox(width: 4),
                      Text("REC $recTime"),
                    ],
                  ),
                ),
              Container(
                width: double.infinity,
                height: 100,
                decoration: BoxDecoration(
                  border:
                      Border.all(color: Theme.of(context).colorScheme.outline),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: CustomPaint(
                  painter: WaveformPainter(
                    samples: controller.blocks,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Scrolling microphone waveform: one vertical bar per amplitude block,
/// newest samples on the right.
class WaveformPainter extends CustomPainter {
  WaveformPainter({
    required this.samples,
    required this.color,
  });

  final List<double> samples;
  final Color color;

  @override
  void paint(Canvas canvas, ui.Size size) {
    final centerY = size.height / 2;
    final paint = Paint()
      ..color = color
      ..strokeWidth = math.max(1, size.width / WaveformController.blockCount)
      ..strokeCap = StrokeCap.round;

    // Baseline
    canvas.drawLine(
      Offset(0, centerY),
      Offset(size.width, centerY),
      Paint()
        ..color = color.withOpacity(0.3)
        ..strokeWidth = 1,
    );

    final step = size.width / WaveformController.blockCount;
    final offset = WaveformController.blockCount - samples.length;
    for (int i = 0; i < samples.length; i++) {
      final x = (offset + i + 0.5) * step;
      final amp = samples[i].clamp(0.0, 1.0) * (size.height / 2 - 2);
      canvas.drawLine(
        Offset(x, centerY - math.max(amp, 0.5)),
        Offset(x, centerY + math.max(amp, 0.5)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(WaveformPainter oldDelegate) {
    return true;
  }
}
