import 'dart:io';
import 'dart:typed_data';

import 'package:ailia_models_flutter/large_language_model/recorded_wav.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wav/wav.dart';

Uint8List extensibleRecording() {
  final bytes = Uint8List(84);
  final header = ByteData.sublistView(bytes);
  bytes.setRange(0, 4, 'RIFF'.codeUnits);
  header.setUint32(4, bytes.length - 8, Endian.little);
  bytes.setRange(8, 12, 'WAVE'.codeUnits);
  bytes.setRange(12, 16, 'fmt '.codeUnits);
  header.setUint32(16, 40, Endian.little);
  header.setUint16(20, 0xfffe, Endian.little);
  header.setUint16(22, 1, Endian.little);
  header.setUint32(24, 16000, Endian.little);
  header.setUint32(28, 32000, Endian.little);
  header.setUint16(32, 2, Endian.little);
  header.setUint16(34, 16, Endian.little);
  header.setUint16(36, 22, Endian.little);
  header.setUint16(38, 16, Endian.little);
  bytes.setRange(44, 60, [
    1,
    0,
    0,
    0,
    0,
    0,
    0x10,
    0,
    0x80,
    0,
    0,
    0xaa,
    0,
    0x38,
    0x9b,
    0x71,
  ]);
  bytes.setRange(60, 64, 'JUNK'.codeUnits);
  header.setUint32(64, 4, Endian.little);
  bytes.setRange(72, 76, 'data'.codeUnits);
  header.setUint32(76, 4, Endian.little);
  bytes.setRange(80, 84, [0, 0, 0xff, 0x7f]);
  return bytes;
}

void main() {
  test('normalizes macOS extensible PCM to standard WAV without changing audio',
      () async {
    final directory = await Directory.systemTemp.createTemp('alm-wav-test-');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/recording.wav');
    await file.writeAsBytes(extensibleRecording());

    expect(await prepareRecordedWav(file), closeTo(2 / 16000, 1e-9));
    final result = await file.readAsBytes();
    final header = ByteData.sublistView(result);
    expect(result.length, 48);
    expect(header.getUint16(20, Endian.little), 1);
    expect(result.sublist(44), [0, 0, 0xff, 0x7f]);
    final wav = await Wav.readFile(file.path);
    expect(wav.channels.single.length, 2);
    expect(wav.samplesPerSecond, 16000);
    expect(await prepareRecordedWav(file), closeTo(2 / 16000, 1e-9));
  });

  test('rejects extensible WAV with a non-PCM subtype', () {
    final bytes = extensibleRecording()..[44] = 3;
    expect(() => normalizeRecordedWav(bytes), throwsFormatException);
  });
}
