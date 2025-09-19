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
    _ailiaLLMModel.open(model.path, nCtx);
    
    // Note: This is a simplified implementation
    // In a full implementation, we would need to add FFI bindings for:
    // - ailiaLLMOpenMultimodalProjectorFile(mmproj.path)
    // - ailiaLLMGetMultimodalCapabilities()
    // - ailiaLLMSetMultimodalPrompt()
    
    // For now, we'll simulate the functionality
    print("Note: Using simplified multimodal implementation");
    print("Loaded model: ${model.path}");
    print("Loaded mmproj: ${mmproj.path}");
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

    // For the demo, we'll create a prompt that includes image description
    // In a real implementation, this would use ailiaLLMSetMultimodalPrompt
    String multimodalPrompt = "$inputText\n\n[Image: $imagePath]\nNote: This is a demo implementation. In the full version, the image would be processed by the multimodal model.";
    
    messages.add({"role": "user", "content": multimodalPrompt});
    
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

  // Helper method to download a file
  static Future<File> downloadFile(String url, String filename) async {
    final response = await http.get(Uri.parse(url));
    final file = File(filename);
    await file.writeAsBytes(response.bodyBytes);
    return file;
  }
}