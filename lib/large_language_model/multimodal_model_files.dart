import 'qnn_model.dart';

/// [folder, body, folder, mmproj] plus [folder, assistant] when [mtp] is
/// requested and the model has an MTP assistant.
List<String> multimodalModelFiles(String type, String backend,
    {String? soc, bool mtp = false}) {
  final files = _multimodalModelFiles(type, backend, soc: soc);
  if (mtp && supportsMtp(type)) {
    return [...files, ...mtpAssistantFiles(type, backend, soc: soc)];
  }
  return files;
}

List<String> _multimodalModelFiles(String type, String backend, {String? soc}) {
  if (isLlmQnnBackend(backend)) {
    if (type != 'gemma4-e2b-vlm' && type != 'gemma4-e2b-alm') {
      throw UnsupportedError('HTP supports only Gemma 4 E2B VLM / ALM.');
    }
    final textFiles = qnnTextModelFiles('gemma4-e2b', soc ?? '');
    return [...textFiles, qnnMmprojFolder, 'gemma4-e2b-$soc-mmproj.qnn'];
  }
  switch (type) {
    case 'gemma3-multimodal':
      return [
        'gemma',
        'gemma-3-4b-it-Q4_K_M.gguf',
        'gemma',
        'gemma-3-4b-it-GGUF_mmproj-model-f16.gguf',
      ];
    case 'gemma4-e2b-vlm':
    case 'gemma4-e2b-alm':
      return [
        'gemma',
        'gemma-4-E2B-it-Q4_K_M.gguf',
        'gemma',
        'gemma-4-E2B-it-mmproj-F16.gguf',
      ];
    default:
      throw UnsupportedError('Unknown multimodal model: $type');
  }
}
