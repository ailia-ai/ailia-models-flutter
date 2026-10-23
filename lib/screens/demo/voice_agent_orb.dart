import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../voice_agent/voice_agent_config.dart';
import '../../voice_agent/voice_agent_orb_motion.dart';

/// Flutter rendering of VoiceAgentOrbView.kt, including its solid white,
/// closed Catmull-Rom outline. PCM arrives separately from text/UI rebuilds.
class VoiceAgentOrb extends StatefulWidget {
  const VoiceAgentOrb({
    super.key,
    required this.audio,
    required this.state,
    this.stateRevision = 0,
  });
  final ValueListenable<List<double>> audio;
  final VoiceAgentState state;
  final int stateRevision;

  @override
  State<VoiceAgentOrb> createState() => _VoiceAgentOrbState();
}

class _VoiceAgentOrbState extends State<VoiceAgentOrb>
    with SingleTickerProviderStateMixin {
  final _motion = VoiceAgentOrbMotion();
  final _clock = Stopwatch();
  final _frame = ValueNotifier<double>(0);
  late final Ticker _ticker;
  double get _now => _clock.elapsedMicroseconds / 1000;

  @override
  void initState() {
    super.initState();
    _clock.start();
    _motion.setState(widget.state);
    widget.audio.addListener(_audioChanged);
    if (widget.audio.value.isNotEmpty) _audioChanged();
    _ticker = createTicker((_) {
      _frame.value = _now;
    })..start();
  }

  void _audioChanged() => _motion.setAudio(widget.audio.value, _now);

  @override
  void didUpdateWidget(VoiceAgentOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state ||
        oldWidget.stateRevision != widget.stateRevision) {
      _motion.setState(widget.state);
    }
    if (oldWidget.audio != widget.audio) {
      oldWidget.audio.removeListener(_audioChanged);
      widget.audio.addListener(_audioChanged);
      _audioChanged();
    }
  }

  @override
  void dispose() {
    widget.audio.removeListener(_audioChanged);
    _ticker.dispose();
    _clock.stop();
    _frame.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Semantics(
    label: widget.state.label,
    child: RepaintBoundary(
      child: CustomPaint(
        size: const Size(240, 240),
        painter: VoiceAgentOrbPainter(_motion, _frame),
      ),
    ),
  );
}

class VoiceAgentOrbPainter extends CustomPainter {
  VoiceAgentOrbPainter(this.motion, this.frame) : super(repaint: frame);
  final VoiceAgentOrbMotion motion;
  final ValueListenable<double> frame;
  final _body = Path();
  final _paint = Paint()
    ..color = Colors.white
    ..isAntiAlias = true;
  final _background = Paint()..color = Colors.black;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, _background);
    motion.advance(frame.value, size.width, size.height);
    final x = motion.pointsX;
    final y = motion.pointsY;
    final count = x.length;
    _body
      ..reset()
      ..moveTo(x[0], y[0]);
    for (var i = 0; i < count; i++) {
      final previous = (i + count - 1) % count;
      final next = (i + 1) % count;
      final following = (i + 2) % count;
      _body.cubicTo(
        x[i] + (x[next] - x[previous]) / 6,
        y[i] + (y[next] - y[previous]) / 6,
        x[next] - (x[following] - x[i]) / 6,
        y[next] - (y[following] - y[i]) / 6,
        x[next],
        y[next],
      );
    }
    _body.close();
    canvas.drawPath(_body, _paint);
  }

  @override
  bool shouldRepaint(VoiceAgentOrbPainter oldDelegate) =>
      oldDelegate.motion != motion || oldDelegate.frame != frame;
}
