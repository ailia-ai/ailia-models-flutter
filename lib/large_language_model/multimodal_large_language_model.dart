import 'dart:io';
import 'dart:typed_data';
import 'package:ailia_llm/ailia_llm_model.dart';
import 'package:http/http.dart' as http;

class MultimodalLargeLanguageModel {
  final AiliaLLMModel _ailiaLLMModel = AiliaLLMModel();

  List<String> getModelList(){
    List<String> modelList = List<String>.empty(growable: true);
    
    // Multimodal Gemma3 model
    modelList.add("gemma");
    modelList.add("gemma-3-4b-it-Q4_K_M.gguf");
    modelList.add("gemma");
    modelList.add("gemma-3-4b-it-GGUF_mmproj-model-f16.gguf");

    return modelList;
  }

  List<Map<String, dynamic>> messages = List<Map<String, dynamic>>.empty(growable:true);
  String systemPrompt = "";

  void open(File model, File mmproj){
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

  String chatWithImage(String inputText, String imagePath){
    if (_ailiaLLMModel.contextFull()){
      messages = List<Map<String, dynamic>>.empty(growable:true);
      _addSystemPrompt();
    }

    // Create multimodal message with image
    String multimodalContent = "$inputText <__media__>";
    Map<String, dynamic> userMessage = {
      "role": "user",
      "content": multimodalContent,
      "media_data": [
        {
          "media_type": "image",
          "file_path": imagePath,
          "width": 0,
          "height": 0
        }
      ]
    };

    messages.add(userMessage);

    _ailiaLLMModel.setMultimodalPrompt(messages);

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

  // Helper method to download a file
  static Future<File> downloadFile(String url, String filename) async {
    final response = await http.get(Uri.parse(url));
    final file = File(filename);
    await file.writeAsBytes(response.bodyBytes);
    return file;
  }
}