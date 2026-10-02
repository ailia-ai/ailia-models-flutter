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
  if (type != 'gemma4-e2b') {
    throw UnsupportedError('QNN is supported only for Gemma 4 E2B.');
  }
  if (!windowsQnnSocs.contains(soc)) {
    throw UnsupportedError('No Windows QNN context binary for SoC "$soc".');
  }
  return ['gemma/qnn/v1.5.0', 'gemma4-e2b-$soc.qnn'];
}
