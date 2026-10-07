import 'dart:io';
import 'dart:isolate';
import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:http/http.dart' as http;
import 'multimodal_model_files.dart';
import 'media_prompt.dart';

class _MediaRequest {
  final SendPort sendPort;
  final String modelPath;
  final String mmprojPath;
  final String backend;
  final int nCtx;
  final String systemPrompt;
  final String inputText;
  final String mediaPath;
  final String mediaType;

  const _MediaRequest({
    required this.sendPort,
    required this.modelPath,
    required this.mmprojPath,
    required this.backend,
    required this.nCtx,
    required this.systemPrompt,
    required this.inputText,
    required this.mediaPath,
    required this.mediaType,
  });
}

void _mediaIsolateFunc(_MediaRequest request) {
  final llm = AiliaLLMModel();
  try {
    final backends = AiliaLLMModel.getBackendList();
    if (!backends.contains(request.backend)) {
      throw Exception(
          "Backend '${request.backend}' not available. Available: $backends");
    }
    llm.open(request.modelPath, request.nCtx, backend: request.backend);
    llm.openMultimodalProjectorFile(request.mmprojPath);
    final capability = request.mediaType == 'audio' ? 'audio' : 'vision';
    if (llm.getMultimodalCapabilities()[capability] != true) {
      throw Exception('$capability capabilities not available');
    }

    llm.setPrompt(mediaPromptMessages(
      systemPrompt: request.systemPrompt,
      inputText: request.inputText,
      mediaPath: request.mediaPath,
      mediaType: request.mediaType,
    ));

    final text = StringBuffer();
    while (true) {
      final delta = llm.generate();
      if (delta == null) break;
      text.write(delta);
      request.sendPort.send({'delta': delta});
    }
    request.sendPort.send({'done': text.toString()});
  } catch (e) {
    request.sendPort.send({'error': '$e'});
  } finally {
    llm.close();
  }
}

class MultimodalLargeLanguageModel {
  final AiliaLLMModel _ailiaLLMModel = AiliaLLMModel();
  Isolate? _isolate;
  ReceivePort? _receivePort;

  static int contextSize(String type) =>
      type == 'gemma4-e2b-vlm' ? 16384 : 8192;

  List<String> getModelList([String type = 'gemma3-multimodal']) =>
      multimodalModelFiles(type);

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

  /// Runs VLM inference outside the UI isolate and streams generated text.
  Future<String> chatWithImageIsolate({
    required File model,
    required File mmproj,
    required String backend,
    required int nCtx,
    required String systemPrompt,
    required String inputText,
    required String imagePath,
    void Function(String delta)? onDelta,
  }) =>
      _chatWithMediaIsolate(
        model: model,
        mmproj: mmproj,
        backend: backend,
        nCtx: nCtx,
        systemPrompt: systemPrompt,
        inputText: inputText,
        mediaPath: imagePath,
        mediaType: 'image',
        onDelta: onDelta,
      );

  /// Runs ALM inference outside the UI isolate and streams generated text.
  Future<String> chatWithAudioIsolate({
    required File model,
    required File mmproj,
    required String backend,
    required int nCtx,
    required String systemPrompt,
    required String inputText,
    required String audioPath,
    void Function(String delta)? onDelta,
  }) =>
      _chatWithMediaIsolate(
        model: model,
        mmproj: mmproj,
        backend: backend,
        nCtx: nCtx,
        systemPrompt: systemPrompt,
        inputText: inputText,
        mediaPath: audioPath,
        mediaType: 'audio',
        onDelta: onDelta,
      );

  Future<String> _chatWithMediaIsolate({
    required File model,
    required File mmproj,
    required String backend,
    required int nCtx,
    required String systemPrompt,
    required String inputText,
    required String mediaPath,
    required String mediaType,
    void Function(String delta)? onDelta,
  }) async {
    final receivePort = ReceivePort();
    _receivePort = receivePort;
    _isolate = await Isolate.spawn(
      _mediaIsolateFunc,
      _MediaRequest(
        sendPort: receivePort.sendPort,
        modelPath: model.path,
        mmprojPath: mmproj.path,
        backend: backend,
        nCtx: nCtx,
        systemPrompt: systemPrompt,
        inputText: inputText,
        mediaPath: mediaPath,
        mediaType: mediaType,
      ),
      onExit: receivePort.sendPort,
    );

    final text = StringBuffer();
    try {
      await for (final message in receivePort) {
        if (message == null) {
          throw Exception('Inference isolate exited unexpectedly');
        }
        final map = message as Map;
        if (map.containsKey('delta')) {
          final delta = map['delta'] as String;
          text.write(delta);
          onDelta?.call(delta);
        } else if (map.containsKey('done')) {
          return map['done'] as String;
        } else if (map.containsKey('error')) {
          throw Exception(map['error']);
        }
      }
      return text.toString();
    } finally {
      receivePort.close();
      _receivePort = null;
      _isolate = null;
    }
  }

  void cancel() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _receivePort?.close();
    _receivePort = null;
  }

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
