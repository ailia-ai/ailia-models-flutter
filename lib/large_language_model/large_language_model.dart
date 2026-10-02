import 'dart:io';

import 'package:ailia_llm/ailia_llm_model.dart';
import 'qnn_model.dart';
import 'qnn_runtime.dart';

class LargeLanguageModel {
  final AiliaLLMModel _ailiaLLMModel = AiliaLLMModel();

  List<String> getModelList([String type = 'gemma2', String backend = '']) {
    if (isLlmQnnBackend(backend)) {
      final soc = availableWindowsQnnSoc();
      if (soc == null) {
        throw UnsupportedError('QNN requires Windows ARM64, a supported SoC '
            '(sc8380xp or qcs6490), and the QNN runtime/NPU driver.');
      }
      return qnnTextModelFiles(type, soc);
    }
    List<String> modelList = List<String>.empty(growable: true);

    if (type == 'gemma4-e2b') {
      modelList.add("gemma");
      modelList.add("gemma-4-E2B-it-Q4_K_M.gguf");
    } else if (type == 'gemma4-e4b') {
      modelList.add("gemma");
      modelList.add("gemma-4-E4B-it-Q4_K_M.gguf");
    } else {
      modelList.add("gemma");
      modelList.add("gemma-2-2b-it-Q4_K_M.gguf");
    }

    return modelList;
  }

  List<Map<String, dynamic>> messages =
      List<Map<String, dynamic>>.empty(growable: true);
  String systemPrompt = "";

  void open(File model) {
    // Initialize backend list before opening model
    List<String> backendList = AiliaLLMModel.getBackendList();

    if (backendList.isEmpty) {
      throw Exception("No backends available for ailia LLM");
    }

    // Use the first available backend
    String backend = backendList[0];

    openWithBackendName(model, backend);
  }

  void openWithBackend(File model, String selectedBackend) {
    // Initialize backend list before opening model
    List<String> backendList = AiliaLLMModel.getBackendList();

    if (backendList.isEmpty) {
      throw Exception("No backends available for ailia LLM");
    }

    // Map environment names to backend names
    String backend;
    if (isLlmQnnBackend(selectedBackend)) {
      backend = selectedBackend;
    } else if (selectedBackend.contains("Vulkan") ||
        selectedBackend.contains("GPU")) {
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

    openWithBackendName(model, backend);
  }

  /// Opens the model with an exact backend name taken from
  /// AiliaLLMModel.getBackendList() (e.g. CPU / Vulkan / OpenCL / Metal).
  void openWithBackendName(File model, String backend) {
    final nCtx = llmContextLength(model.path, backend);

    List<String> backendList = AiliaLLMModel.getBackendList();
    if (!backendList.contains(backend)) {
      throw Exception(
          "Backend '$backend' not available. Available: $backendList");
    }

    _ailiaLLMModel.open(model.path, nCtx, backend: backend);
  }

  void setSystemPrompt(String prompt) {
    systemPrompt = prompt;
    _addSystemPrompt();
  }

  /// Clears the conversation history, optionally replacing the system
  /// prompt, so a fresh conversation can start on the same model.
  void resetHistory({String? newSystemPrompt}) {
    if (newSystemPrompt != null) {
      systemPrompt = newSystemPrompt;
    }
    messages = List<Map<String, dynamic>>.empty(growable: true);
    _addSystemPrompt();
  }

  void _addSystemPrompt() {
    if (systemPrompt == "") {
      return;
    }
    messages.add({"role": "system", "content": systemPrompt});
  }

  String chat(String inputText) {
    if (_ailiaLLMModel.contextFull()) {
      messages = List<Map<String, dynamic>>.empty(growable: true);
      _addSystemPrompt();
    }

    messages.add({"role": "user", "content": inputText});

    _ailiaLLMModel.setPrompt(messages);
    String text = "";
    while (true) {
      String? deltaText = _ailiaLLMModel.generate();
      if (deltaText == null) {
        break;
      }
      text = text + deltaText;
    }

    messages.add({"role": "assistant", "content": text});
    return text;
  }

  /// Same as [chat] but reports each generated token through [onDelta]
  /// and yields to the event loop so the UI can update while generating.
  /// Generation stops early when [shouldContinue] returns false (e.g.
  /// the screen owning the model has been disposed).
  Future<String> chatStream(
      String inputText, void Function(String delta) onDelta,
      {bool Function()? shouldContinue}) async {
    if (_ailiaLLMModel.contextFull()) {
      messages = List<Map<String, dynamic>>.empty(growable: true);
      _addSystemPrompt();
    }

    messages.add({"role": "user", "content": inputText});

    _ailiaLLMModel.setPrompt(messages);
    String text = "";
    while (shouldContinue == null || shouldContinue()) {
      String? deltaText = _ailiaLLMModel.generate();
      if (deltaText == null) {
        break;
      }
      text = text + deltaText;
      onDelta(deltaText);
      // Let the UI repaint between tokens.
      await Future.delayed(Duration.zero);
    }

    messages.add({"role": "assistant", "content": text});
    return text;
  }

  void close() {
    _ailiaLLMModel.close();
  }
}
