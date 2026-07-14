//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <ailia/ailia_plugin_c_api.h>
#include <ailia_audio/ailia_audio_plugin_c_api.h>
#include <ailia_llm/ailia_llm_plugin_c_api.h>
#include <ailia_speech/ailia_speech_plugin_c_api.h>
#include <ailia_tokenizer/ailia_tokenizer_plugin_c_api.h>
#include <ailia_tracker/ailia_tracker_plugin_c_api.h>
#include <ailia_voice/ailia_voice_plugin_c_api.h>
#include <audioplayers_windows/audioplayers_windows_plugin.h>
#include <camera_windows/camera_windows.h>
#include <permission_handler_windows/permission_handler_windows_plugin.h>
#include <record_windows/record_windows_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  AiliaPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AiliaPluginCApi"));
  AiliaAudioPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AiliaAudioPluginCApi"));
  AiliaLlmPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AiliaLlmPluginCApi"));
  AiliaSpeechPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AiliaSpeechPluginCApi"));
  AiliaTokenizerPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AiliaTokenizerPluginCApi"));
  AiliaTrackerPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AiliaTrackerPluginCApi"));
  AiliaVoicePluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AiliaVoicePluginCApi"));
  AudioplayersWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AudioplayersWindowsPlugin"));
  CameraWindowsRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("CameraWindows"));
  PermissionHandlerWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("PermissionHandlerWindowsPlugin"));
  RecordWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("RecordWindowsPluginCApi"));
}
