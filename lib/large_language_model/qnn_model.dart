bool isLlmQnnBackend(String backend) {
  final name = backend.toUpperCase();
  return name == 'HTP' ||
      name.startsWith('HTP (QNN)') ||
      name.startsWith('HTP:');
}

const windowsQnnSocs = {'sc8380xp', 'qcs6490'};

int llmContextLength(String path, String backend) {
  final qnn = isLlmQnnBackend(backend);
  if (qnn != path.toLowerCase().endsWith('.qnn')) {
    throw ArgumentError(
        'QNN requires a .qnn context binary; CPU/GPU requires GGUF.');
  }
  return qnn ? 0 : 8192;
}

/// Packages contain precompiled context binaries and tokenizer data.
/// Never substitute a different SoC's package or a GGUF for QNN.
List<String> qnnTextModelFiles(String type, String soc) {
  if (type != 'gemma4-e2b' && type != 'gemma4-e4b') {
    throw UnsupportedError('QNN supports Gemma 4 E2B / E4B.');
  }
  if (!windowsQnnSocs.contains(soc)) {
    throw UnsupportedError('No Windows QNN context binary for SoC "$soc".');
  }
  if (type == 'gemma4-e4b' && soc != 'sc8380xp') {
    throw UnsupportedError('Gemma 4 E4B requires sc8380xp on Windows HTP.');
  }
  return ['gemma/qnn/v1.5.0', '$type-$soc.qnn'];
}
