import 'dart:io';
import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:http/http.dart' as http;
import 'multimodal_model_files.dart';
import 'media_prompt.dart';
import 'multimodal_worker.dart';

class MultimodalLargeLanguageModel {
  final AiliaLLMModel _ailiaLLMModel = AiliaLLMModel();
  final MultimodalWorker _worker = MultimodalWorker();

  static int contextSize(String type) =>
      type == 'gemma4-e2b-vlm' ? 16384 : 8192;

  List<String> getModelList(
          [String type = 'gemma3-multimodal', bool mtp = false]) =>
      multimodalModelFiles(type, mtp: mtp);

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
    const nCtx = 8192;

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

  bool _resetHistory = false;

  /// Starts a new conversation on the next turn, keeping the model loaded.
  void clearHistory() => _resetHistory = true;

  /// Runs one VLM chat turn outside the UI isolate and streams generated
  /// text. Earlier turns stay in the conversation; [imagePath] is null for
  /// a text-only follow-up question.
  Future<String> chatWithImageIsolate({
    required File model,
    required File mmproj,
    required String backend,
    required int nCtx,
    required String systemPrompt,
    required String inputText,
    String? imagePath,
    File? mtpAssistant,
    void Function(String delta)? onDelta,
    void Function(double? ttftMs, double? tps)? onMetrics,
    void Function()? onModelLoading,
    void Function(String? mtpError)? onModelLoaded,
    void Function()? onHistoryReset,
  }) =>
      _chatWithMediaIsolate(
        model: model,
        mmproj: mmproj,
        mtpAssistant: mtpAssistant,
        backend: backend,
        nCtx: nCtx,
        systemPrompt: systemPrompt,
        inputText: inputText,
        mediaPath: imagePath,
        mediaType: 'image',
        onDelta: onDelta,
        onMetrics: onMetrics,
        onModelLoading: onModelLoading,
        onModelLoaded: onModelLoaded,
        onHistoryReset: onHistoryReset,
      );

  /// Runs one ALM chat turn outside the UI isolate and streams generated
  /// text. Earlier turns stay in the conversation; [audioPath] is null for
  /// a text-only follow-up question.
  Future<String> chatWithAudioIsolate({
    required File model,
    required File mmproj,
    required String backend,
    required int nCtx,
    required String systemPrompt,
    required String inputText,
    String? audioPath,
    File? mtpAssistant,
    void Function(String delta)? onDelta,
    void Function(double? ttftMs, double? tps)? onMetrics,
    void Function()? onModelLoading,
    void Function(String? mtpError)? onModelLoaded,
    void Function()? onHistoryReset,
  }) =>
      _chatWithMediaIsolate(
        model: model,
        mmproj: mmproj,
        mtpAssistant: mtpAssistant,
        backend: backend,
        nCtx: nCtx,
        systemPrompt: systemPrompt,
        inputText: inputText,
        mediaPath: audioPath,
        mediaType: 'audio',
        onDelta: onDelta,
        onMetrics: onMetrics,
        onModelLoading: onModelLoading,
        onModelLoaded: onModelLoaded,
        onHistoryReset: onHistoryReset,
      );

  Future<String> _chatWithMediaIsolate({
    required File model,
    required File mmproj,
    required String backend,
    required int nCtx,
    required String systemPrompt,
    required String inputText,
    required String? mediaPath,
    required String mediaType,
    File? mtpAssistant,
    void Function(String delta)? onDelta,
    void Function(double? ttftMs, double? tps)? onMetrics,
    void Function()? onModelLoading,
    void Function(String? mtpError)? onModelLoaded,
    void Function()? onHistoryReset,
  }) {
    final resetHistory = _resetHistory;
    _resetHistory = false;
    return _worker.run({
      'modelPath': model.path,
      'mmprojPath': mmproj.path,
      'mtpPath': mtpAssistant?.path ?? '',
      'backend': backend,
      'nCtx': nCtx,
      'systemPrompt': systemPrompt,
      'inputText': inputText,
      'mediaPath': mediaPath,
      'mediaType': mediaType,
      'resetHistory': resetHistory,
    }, onEvent: (event) {
      switch (event['type']) {
        case 'loading':
          onModelLoading?.call();
        case 'historyReset':
          onHistoryReset?.call();
        case 'ready':
          onModelLoaded?.call(event['mtpError'] as String?);
        case 'delta':
          onDelta?.call(event['text'] as String);
        case 'metrics':
          onMetrics?.call((event['ttftMs'] as num?)?.toDouble(),
              (event['tps'] as num?)?.toDouble());
      }
    });
  }

  /// Releases the persistent worker, stopping generation between tokens.
  void cancel() => _worker.cancel();

  void close() {
    cancel();
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
