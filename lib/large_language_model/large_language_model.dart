import 'dart:io';

import 'package:ailia_llm/ailia_llm_model.dart';

class LargeLanguageModel {
  final AiliaLLMModel _ailiaLLMModel = AiliaLLMModel();

  List<String> getModelList(){
    List<String> modelList = List<String>.empty(growable: true);

    modelList.add("gemma");
    modelList.add("gemma-2-2b-it-Q4_K_M.gguf");

    return modelList;
  }

  List<Map<String, dynamic>> messages = List<Map<String, dynamic>>.empty(growable:true);
  String systemPrompt = "";

  void open(File model){
    int nCtx = 8192; // 0 for modelDefault

    // Initialize backend list before opening model
    List<String> backendList = AiliaLLMModel.getBackendList();

    if (backendList.isEmpty) {
      throw Exception("No backends available for ailia LLM");
    }

    // Use the first available backend
    String backend = backendList[0];

    _ailiaLLMModel.open(model.path, nCtx, backend: backend);
  }

  void openWithBackend(File model, String selectedBackend){
    int nCtx = 8192; // 0 for modelDefault

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
      throw Exception("Selected backend '$backend' not available. Available: $backendList");
    }

    _ailiaLLMModel.open(model.path, nCtx, backend: backend);
  }

  /// Opens the model with an exact backend name taken from
  /// AiliaLLMModel.getBackendList() (e.g. CPU / Vulkan / OpenCL / Metal).
  void openWithBackendName(File model, String backend){
    int nCtx = 8192; // 0 for modelDefault

    List<String> backendList = AiliaLLMModel.getBackendList();
    if (!backendList.contains(backend)) {
      throw Exception("Backend '$backend' not available. Available: $backendList");
    }

    _ailiaLLMModel.open(model.path, nCtx, backend: backend);
  }

  void setSystemPrompt(String prompt){
    systemPrompt = prompt;
    _addSystemPrompt();
  }

  void _addSystemPrompt(){
    if (systemPrompt == ""){
      return;
    }
    messages.add({"role": "system", "content": systemPrompt});
  }

  String chat(String inputText){
    if (_ailiaLLMModel.contextFull()){
      messages = List<Map<String, dynamic>>.empty(growable:true);
      _addSystemPrompt();
    }

    messages.add({"role": "user", "content": inputText});
    
    _ailiaLLMModel.setPrompt(messages);
    String text = "";
    while(true){
      String? deltaText = _ailiaLLMModel.generate();
      if (deltaText == null){
        break;
      }
      text = text + deltaText;
    }

    messages.add({"role": "assistant", "content": text});
    return text;
  }

  void close(){
    _ailiaLLMModel.close();
  }
}
