#include "include/playout_audio/playout_audio_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "playout_audio_plugin.h"
void PlayoutAudioPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  playout_audio::PlayoutAudioPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
