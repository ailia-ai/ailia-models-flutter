import 'qnn_model.dart';

List<String> multimodalModelFiles(String type, String backend, {String? soc}) {
  if (isLlmQnnBackend(backend)) {
    if (type != 'gemma4-e2b-vlm' && type != 'gemma4-e2b-alm') {
      throw UnsupportedError('HTP supports only Gemma 4 E2B VLM / ALM.');
    }
    final textFiles = qnnTextModelFiles('gemma4-e2b', soc ?? '');
    return [...textFiles, textFiles[0], 'gemma4-e2b-$soc-mmproj.qnn'];
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
