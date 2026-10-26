import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:ailia_models_flutter/screens/demo/voice_agent_orb.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_config.dart';
import 'package:ailia_models_flutter/voice_agent/voice_agent_orb_motion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final reference =
      jsonDecode(
            File(
              'test/fixtures/voice_agent_orb_kotlin.json',
            ).readAsStringSync(),
          )
          as Map;
  test(
    'all 48 points, 12 PCM levels and phase match original Kotlin frames',
    () {
      final motion = VoiceAgentOrbMotion();
      for (final frame in reference['frames'] as List) {
        final now = (frame['nowMs'] as num).toDouble();
        final state = frame['state'] as String?;
        if (state != null) {
          motion.setState(
            VoiceAgentState.values.singleWhere(
              (s) => s.name.toUpperCase() == state.replaceAll('_', ''),
            ),
          );
        }
        if (frame['samples'] != null) {
          motion.setAudio(
            (frame['samples'] as List)
                .cast<num>()
                .map((n) => n.toDouble())
                .toList(),
            now,
          );
        }
        motion.advance(now, 240, 240);
        final expected = frame['expected'] as Map;
        void compare(List<double> actual, String name, double tolerance) {
          final values = (expected[name] as List).cast<num>();
          expect(actual.length, values.length);
          for (var i = 0; i < actual.length; i++) {
            expect(
              actual[i],
              closeTo(values[i], tolerance),
              reason: 'frame=$now $name[$i]',
            );
          }
        }

        compare(motion.pointsX, 'pointsX', .001);
        compare(motion.pointsY, 'pointsY', .001);
        compare(motion.levels, 'levels', .000001);
        expect(
          motion.energy,
          closeTo(expected['energy'] as num, .000001),
          reason: 'energy at $now',
        );
        expect(
          motion.targetEnergy,
          closeTo(expected['targetEnergy'] as num, .000001),
          reason: 'target at $now',
        );
        expect(
          motion.motionPhase,
          closeTo(expected['motionPhase'] as num, .000001),
          reason: 'phase at $now',
        );
      }
    },
  );

  test('every session state uses the Kotlin idle or busy speed', () {
    final busy = {
      VoiceAgentState.preparing,
      VoiceAgentState.recognizing,
      VoiceAgentState.thinking,
      VoiceAgentState.synthesizing,
      VoiceAgentState.synthesizingQuery,
      VoiceAgentState.cancelling,
    };
    for (final state in VoiceAgentState.values) {
      final motion = VoiceAgentOrbMotion()
        ..setState(state)
        ..advance(0, 320, 200);
      expect(
        motion.motionPhase,
        closeTo(.016 * (busy.contains(state) ? .7 : .35), 1e-9),
        reason: state.name,
      );
    }
  });

  test(
    'quiet input, attack, decay, repeated states and stale audio follow Kotlin',
    () {
      final motion = VoiceAgentOrbMotion()..setState(VoiceAgentState.listening);
      motion.setAudio(List.filled(120, .008), 0);
      expect(motion.targetEnergy, 0);
      motion.setAudio(List.filled(120, .2), 0);
      final target = min(sqrt(.2 - .008) * 2.2, 1);
      motion.advance(0, 240, 240);
      expect(motion.energy, closeTo(target * (1 - exp(-.016 / .045)), 1e-9));
      final before = motion.energy;
      final level = motion.levels.first;
      motion.advance(181, 240, 240);
      expect(motion.targetEnergy, 0);
      expect(motion.energy, closeTo(before * exp(-.05 / .2), 1e-9));
      expect(motion.levels.first, closeTo(level * exp(-.05 / .2), 1e-7));
      motion.setAudio(List.filled(120, .1), 200);
      motion.setState(VoiceAgentState.listening);
      expect(motion.levels, everyElement(0));
      expect(motion.targetEnergy, 0);
      expect(motion.energy, greaterThan(0));
    },
  );

  testWidgets(
    'rendering uses a closed white body on black, without a gradient',
    (tester) async {
      final motion = VoiceAgentOrbMotion()..setState(VoiceAgentState.listening);
      final frame = ValueNotifier<double>(0);
      final painter = VoiceAgentOrbPainter(motion, frame);
      final canvas = TestRecordingCanvas();
      painter.paint(canvas, const Size(240, 240));
      final pathCall = canvas.invocations.singleWhere(
        (i) => i.invocation.memberName == #drawPath,
      );
      final args = pathCall.invocation.positionalArguments;
      final path = args[0] as ui.Path;
      final paint = args[1] as Paint;
      expect(path.computeMetrics().single.isClosed, isTrue);
      expect(paint.color, Colors.white);
      expect(paint.shader, isNull);
      expect(paint.maskFilter, isNull);
      expect(paint.isAntiAlias, isTrue);
      frame.dispose();
    },
  );

  testWidgets(
    'PCM updates, repeated state events and ticker disposal reach the orb',
    (tester) async {
      final audio = ValueNotifier<List<double>>(const []);
      var revision = 0;
      Widget orb() => MaterialApp(
        home: Center(
          child: VoiceAgentOrb(
            audio: audio,
            state: VoiceAgentState.speaking,
            stateRevision: revision,
          ),
        ),
      );
      await tester.pumpWidget(orb());
      VoiceAgentOrbPainter painter() =>
          tester
                  .widget<CustomPaint>(
                    find.descendant(
                      of: find.byType(VoiceAgentOrb),
                      matching: find.byType(CustomPaint),
                    ),
                  )
                  .painter!
              as VoiceAgentOrbPainter;
      audio.value = List.filled(120, .4);
      expect(painter().motion.targetEnergy, greaterThan(0));
      await tester.pump(const Duration(milliseconds: 16));
      expect(painter().motion.energy, greaterThan(0));
      revision++;
      await tester.pumpWidget(orb());
      expect(painter().motion.targetEnergy, 0);
      expect(painter().motion.levels, everyElement(0));
      await tester.pumpWidget(const SizedBox());
      audio.value = const [];
      audio.dispose();
      expect(tester.takeException(), isNull);
    },
  );

  test('raster output has a white body and black background', () async {
    final motion = VoiceAgentOrbMotion()..setState(VoiceAgentState.speaking);
    final audio = List.filled(120, .3);
    for (var i = 0; i < 15; i++) {
      motion.setAudio(audio, i * 16);
      motion.advance(i * 16, 240, 240);
    }
    final frame = ValueNotifier<double>(240);
    final recorder = ui.PictureRecorder();
    VoiceAgentOrbPainter(
      motion,
      frame,
    ).paint(ui.Canvas(recorder), const Size(240, 240));
    final picture = recorder.endRecording();
    final image = await picture.toImage(240, 240);
    final bytes = (await image.toByteData())!;
    const center = (120 * 240 + 120) * 4;
    expect(
      [for (var i = 0; i < 4; i++) bytes.getUint8(center + i)],
      [255, 255, 255, 255],
    );
    expect([for (var i = 0; i < 4; i++) bytes.getUint8(i)], [0, 0, 0, 255]);
    final preview = Platform.environment['AILIA_VOICE_AGENT_ORB_PREVIEW'];
    if (preview != null) {
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(preview).writeAsBytesSync(png!.buffer.asUint8List());
    }
    image.dispose();
    picture.dispose();
    frame.dispose();
  });
}
