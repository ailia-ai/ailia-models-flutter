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
  // MTP-capable bodies also generate normally when no assistant is opened.
  return [qnnModelFolder, '$type-$soc-${qnnPrecision(soc)}-mtp.qnn'];
}

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
