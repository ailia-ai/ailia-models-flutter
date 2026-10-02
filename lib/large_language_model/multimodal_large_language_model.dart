import 'dart:io';
import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:http/http.dart' as http;
import 'qnn_model.dart';
import 'qnn_runtime.dart';
import 'multimodal_model_files.dart';
import 'media_prompt.dart';

class MultimodalLargeLanguageModel {
  final AiliaLLMModel _ailiaLLMModel = AiliaLLMModel();

  List<String> getModelList(
      [String type = 'gemma3-multimodal', String backend = '']) {
    return multimodalModelFiles(type, backend,
        soc: isLlmQnnBackend(backend) ? availableWindowsQnnSoc() : null);
  }

  List<Map<String, dynamic>> messages =
      List<Map<String, dynamic>>.empty(growable: true);
  String systemPrompt = "";

  void open(File model, File mmproj) {
    int nCtx = 8192; // Context size for multimodal model

    // Initialize backend list before opening model
    List<String> backendList = AiliaLLMModel.getBackendList();

    if (backendList.isEmpty) {
      throw Exception("No backends available for ailia LLM");
    }

    // Use the first available backend
    String backend = backendList[0];

    // Open the base text model
    _ailiaLLMModel.open(model.path, nCtx, backend: backend);

    // Open the multimodal projector
    _ailiaLLMModel.openMultimodalProjectorFile(mmproj.path);

    // Get multimodal capabilities to verify setup
    Map<String, bool> capabilities = _ailiaLLMModel.getMultimodalCapabilities();
    if (!capabilities['vision']!) {
      throw Exception("Vision capabilities not available");
    }
  }

  void openWithBackend(File model, File mmproj, String selectedBackend) {
    int nCtx = 8192; // Context size for multimodal model

    // Initialize backend list before opening model
    List<String> backendList = AiliaLLMModel.getBackendList();

    if (backendList.isEmpty) {
      throw Exception("No backends available for ailia LLM");
    }

    // Map environment names to backend names
    String backend;
    if (selectedBackend.contains("Vulkan") || selectedBackend.contains("GPU")) {
      backend = "Vulkan";
    } else if (selectedBackend.contains("Metal")) {
      backend = "Metal";
    } else {
      backend = "CPU";
    }

    // Verify the selected backend is available
    if (!backendList.contains(backend)) {
      throw Exception(
          "Selected backend '$backend' not available. Available: $backendList");
    }

    // Open the base text model with selected backend
    _ailiaLLMModel.open(model.path, nCtx, backend: backend);

    // Open the multimodal projector
    _ailiaLLMModel.openMultimodalProjectorFile(mmproj.path);

    // Get multimodal capabilities to verify setup
    Map<String, bool> capabilities = _ailiaLLMModel.getMultimodalCapabilities();
    if (!capabilities['vision']!) {
      throw Exception("Vision capabilities not available");
    }
  }

  /// Opens the model with an exact backend name taken from
  /// AiliaLLMModel.getBackendList() (e.g. CPU / Vulkan / OpenCL / Metal).
  void openWithBackendName(File model, File mmproj, String backend,
      {String mediaType = 'image'}) {
    if (mediaType != 'image' && mediaType != 'audio') {
      throw ArgumentError('Unsupported media type: $mediaType');
    }
    final nCtx = llmContextLength(model.path, backend);
    llmContextLength(mmproj.path, backend);

    List<String> backendList = AiliaLLMModel.getBackendList();
    if (!backendList.contains(backend)) {
      throw Exception(
          "Backend '$backend' not available. Available: $backendList");
    }

    _ailiaLLMModel.open(model.path, nCtx, backend: backend);

    // Open the multimodal projector
    _ailiaLLMModel.openMultimodalProjectorFile(mmproj.path);

    // Get multimodal capabilities to verify setup
    Map<String, bool> capabilities = _ailiaLLMModel.getMultimodalCapabilities();
    if (capabilities[mediaType == 'audio' ? 'audio' : 'vision'] != true) {
      throw Exception('$mediaType capabilities not available');
    }
  }

  void setSystemPrompt(String prompt) {
    systemPrompt = prompt;
    _addSystemPrompt();
  }

  void _addSystemPrompt() {
    if (systemPrompt == "") {
      return;
    }
    messages.add({"role": "system", "content": systemPrompt});
  }

  String chatWithImage(String inputText, String imagePath) {
    _setMediaPrompt(inputText, imagePath, 'image');
    String text = "";
    while (true) {
      String? deltaText = _ailiaLLMModel.generate();
      if (deltaText == null) break;
      text += deltaText;
    }
    messages.add({"role": "assistant", "content": text});
    return text;
  }

  void _setMediaPrompt(String inputText, String path, String mediaType) {
    if (_ailiaLLMModel.contextFull()) {
      messages = List<Map<String, dynamic>>.empty(growable: true);
      _addSystemPrompt();
    }

    messages.add(mediaPromptMessage(inputText, path, mediaType));
    _ailiaLLMModel.setPrompt(messages);
  }

  Future<String> chatWithAudioStream(
      String inputText, String audioPath, void Function(String) onDelta,
      {bool Function()? shouldContinue}) async {
    _setMediaPrompt(inputText, audioPath, 'audio');
    String text = "";
    while (shouldContinue == null || shouldContinue()) {
      String? deltaText = _ailiaLLMModel.generate();
      if (deltaText == null) {
        break;
      }
      text = text + deltaText;
      onDelta(deltaText);
      await Future.delayed(Duration.zero);
    }

    messages.add({"role": "assistant", "content": text});
    return text;
  }

  void close() {
    _ailiaLLMModel.close();
  }

  // Helper method to download a file
  static Future<File> downloadFile(String url, String filename) async {
    final response = await http.get(Uri.parse(url));
    final file = File(filename);
    await file.writeAsBytes(response.bodyBytes);
    return file;
  }
}
