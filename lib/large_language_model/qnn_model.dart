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
  if (qnnModelFormat == QnnModelFormat.v150) {
    // Pre-MTP context binaries, for checking compatibility with the
    // current library. They have no AR-4 graph, so MTP cannot open.
    return [qnnMmprojFolder, '$type-$soc.qnn'];
  }
  // MTP-capable bodies also generate normally when no assistant is opened.
  return [qnnModelFolder, '$type-$soc-${qnnPrecision(soc)}-mtp.qnn'];
}

/// Published QNN context binary formats for the Gemma 4 text body.
enum QnnModelFormat {
  v150('v1.5.0'),
  v151('v1.5.1');

  const QnnModelFormat(this.label);
  final String label;
}

/// Debug option chosen in Settings. Not persisted: every launch starts
/// with the MTP-capable v1.5.1 format.
QnnModelFormat qnnModelFormat = QnnModelFormat.v151;

/// ailia LLM 1.5.1 context binaries (QAIRT 2.47) with the AR-4 MTP graph.
const qnnModelFolder = 'gemma/qnn/v1.5.1';

/// The 1.5.0 projectors are compatible with the 1.5.1 MTP bodies.
const qnnMmprojFolder = 'gemma/qnn/v1.5.0';

/// Activation precision of the published context binaries per SoC.
String qnnPrecision(String soc) =>
    soc == 'sm8475' || soc == 'sc8380xp' ? 'fp16' : 'int16';

/// Number of draft tokens the MTP assistant proposes per verification.
const mtpDraftTokens = 3;

/// Gemma 4 models with a published MTP assistant (draft model).
bool supportsMtp(String type) =>
    type == 'gemma4-e2b' ||
    type == 'gemma4-e4b' ||
    type == 'gemma4-e2b-vlm' ||
    type == 'gemma4-e2b-alm' ||
    type == 'gemma4-e2b-tool-use';

/// Whether MTP can be used for [type] on [backend]. The v1.5.0 QNN
/// context binaries have no AR-4 verification graph, so MTP is off there.
bool mtpAvailable(String type, String backend) =>
    supportsMtp(type) &&
    !(isLlmQnnBackend(backend) && qnnModelFormat == QnnModelFormat.v150);

/// [folder, file] of the MTP assistant matching the body opened for
/// [type] on [backend]. The assistant must share the body's SoC, model
/// and precision on QNN, and its vocabulary / hidden size on GGUF.
List<String> mtpAssistantFiles(String type, String backend, {String? soc}) {
  final model = switch (type) {
    'gemma4-e4b' => 'e4b',
    _ when supportsMtp(type) => 'e2b',
    _ => throw UnsupportedError('No MTP assistant for $type'),
  };
  if (isLlmQnnBackend(backend)) {
    // Validates the SoC / model combination like the body files.
    qnnTextModelFiles('gemma4-$model', soc ?? '');
    return [
      qnnModelFolder,
      'gemma4-$model-$soc-${qnnPrecision(soc!)}-mtp-assistant.qnn'
    ];
  }
  return ['gemma', 'mtp-gemma-4-${model.toUpperCase()}-it-Q4_0.gguf'];
}
