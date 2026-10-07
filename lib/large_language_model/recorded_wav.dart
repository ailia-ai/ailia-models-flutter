import 'dart:io';
import 'dart:typed_data';

const _pcmSubtype = <int>[
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
];

bool _hasTag(Uint8List bytes, int offset, String tag) {
  if (offset < 0 || offset + tag.length > bytes.length) return false;
  for (var i = 0; i < tag.length; i++) {
    if (bytes[offset + i] != tag.codeUnitAt(i)) return false;
  }
  return true;
}

/// Converts a 16-bit WAVE_FORMAT_EXTENSIBLE PCM recording to a canonical
/// PCM WAV header. The sample bytes are copied unchanged.
({Uint8List bytes, double seconds}) normalizeRecordedWav(Uint8List bytes) {
  if (bytes.length < 12 ||
      !_hasTag(bytes, 0, 'RIFF') ||
      !_hasTag(bytes, 8, 'WAVE')) {
    throw const FormatException('The recording is not a RIFF/WAVE file.');
  }

  final header = ByteData.sublistView(bytes);
  int? fmtOffset;
  int? fmtSize;
  int? dataOffset;
  int? dataSize;
  var offset = 12;
  while (offset + 8 <= bytes.length) {
    final size = header.getUint32(offset + 4, Endian.little);
    final start = offset + 8;
    final end = start + size;
    if (end > bytes.length) {
      throw const FormatException('The recording has a truncated WAV chunk.');
    }
    if (_hasTag(bytes, offset, 'fmt ') && fmtOffset == null) {
      fmtOffset = start;
      fmtSize = size;
    } else if (_hasTag(bytes, offset, 'data') && dataOffset == null) {
      dataOffset = start;
      dataSize = size;
    }
    offset = end + (size.isOdd ? 1 : 0);
  }

  if (fmtOffset == null ||
      fmtSize == null ||
      fmtSize < 16 ||
      dataOffset == null ||
      dataSize == null) {
    throw const FormatException('The recording has no valid fmt/data chunk.');
  }
  final format = header.getUint16(fmtOffset, Endian.little);
  final channels = header.getUint16(fmtOffset + 2, Endian.little);
  final sampleRate = header.getUint32(fmtOffset + 4, Endian.little);
  final byteRate = header.getUint32(fmtOffset + 8, Endian.little);
  final blockAlign = header.getUint16(fmtOffset + 12, Endian.little);
  final bits = header.getUint16(fmtOffset + 14, Endian.little);
  if (channels == 0 ||
      sampleRate == 0 ||
      bits != 16 ||
      blockAlign != channels * 2 ||
      byteRate != sampleRate * blockAlign) {
    throw const FormatException('Expected a 16-bit PCM WAV recording.');
  }
  if (dataSize == 0 || dataSize % blockAlign != 0) {
    throw const FormatException(
        'The microphone recording is empty or incomplete.');
  }

  if (format == 1) {
    return (bytes: bytes, seconds: dataSize / byteRate);
  }
  if (format != 0xfffe ||
      fmtSize < 40 ||
      header.getUint16(fmtOffset + 16, Endian.little) < 22 ||
      header.getUint16(fmtOffset + 18, Endian.little) != 16) {
    throw FormatException('Unsupported WAV format: $format, $bits');
  }
  for (var i = 0; i < _pcmSubtype.length; i++) {
    if (bytes[fmtOffset + 24 + i] != _pcmSubtype[i]) {
      throw const FormatException('Unsupported WAV extensible subtype.');
    }
  }
  if (dataSize > 0xffffffff - 36) {
    throw const FormatException('The recording exceeds the WAV size limit.');
  }

  final normalized = Uint8List(44 + dataSize);
  normalized.setRange(0, 4, 'RIFF'.codeUnits);
  normalized.setRange(8, 12, 'WAVE'.codeUnits);
  normalized.setRange(12, 16, 'fmt '.codeUnits);
  normalized.setRange(36, 40, 'data'.codeUnits);
  final output = ByteData.sublistView(normalized);
  output.setUint32(4, 36 + dataSize, Endian.little);
  output.setUint32(16, 16, Endian.little);
  output.setUint16(20, 1, Endian.little);
  output.setUint16(22, channels, Endian.little);
  output.setUint32(24, sampleRate, Endian.little);
  output.setUint32(28, byteRate, Endian.little);
  output.setUint16(32, blockAlign, Endian.little);
  output.setUint16(34, 16, Endian.little);
  output.setUint32(40, dataSize, Endian.little);
  normalized.setRange(44, normalized.length, bytes, dataOffset);
  return (bytes: normalized, seconds: dataSize / byteRate);
}

Future<double> prepareRecordedWav(File file) async {
  final original = await file.readAsBytes();
  final result = normalizeRecordedWav(original);
  if (!identical(result.bytes, original)) {
    await file.writeAsBytes(result.bytes, flush: true);
  }
  return result.seconds;
}
