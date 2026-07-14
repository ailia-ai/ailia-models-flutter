//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <ailia/ailia_plugin.h>
#include <ailia_audio/ailia_audio_plugin.h>
#include <ailia_llm/ailia_llm_plugin.h>
#include <ailia_speech/ailia_speech_plugin.h>
#include <ailia_tokenizer/ailia_tokenizer_plugin.h>
#include <ailia_tracker/ailia_tracker_plugin.h>
#include <ailia_voice/ailia_voice_plugin.h>
#include <audioplayers_linux/audioplayers_linux_plugin.h>
#include <record_linux/record_linux_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) ailia_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AiliaPlugin");
  ailia_plugin_register_with_registrar(ailia_registrar);
  g_autoptr(FlPluginRegistrar) ailia_audio_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AiliaAudioPlugin");
  ailia_audio_plugin_register_with_registrar(ailia_audio_registrar);
  g_autoptr(FlPluginRegistrar) ailia_llm_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AiliaLlmPlugin");
  ailia_llm_plugin_register_with_registrar(ailia_llm_registrar);
  g_autoptr(FlPluginRegistrar) ailia_speech_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AiliaSpeechPlugin");
  ailia_speech_plugin_register_with_registrar(ailia_speech_registrar);
  g_autoptr(FlPluginRegistrar) ailia_tokenizer_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AiliaTokenizerPlugin");
  ailia_tokenizer_plugin_register_with_registrar(ailia_tokenizer_registrar);
  g_autoptr(FlPluginRegistrar) ailia_tracker_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AiliaTrackerPlugin");
  ailia_tracker_plugin_register_with_registrar(ailia_tracker_registrar);
  g_autoptr(FlPluginRegistrar) ailia_voice_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AiliaVoicePlugin");
  ailia_voice_plugin_register_with_registrar(ailia_voice_registrar);
  g_autoptr(FlPluginRegistrar) audioplayers_linux_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "AudioplayersLinuxPlugin");
  audioplayers_linux_plugin_register_with_registrar(audioplayers_linux_registrar);
  g_autoptr(FlPluginRegistrar) record_linux_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "RecordLinuxPlugin");
  record_linux_plugin_register_with_registrar(record_linux_registrar);
}
