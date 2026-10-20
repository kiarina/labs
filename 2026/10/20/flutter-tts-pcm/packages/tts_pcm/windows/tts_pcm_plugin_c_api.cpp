#include "include/tts_pcm/tts_pcm_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "tts_pcm_plugin.h"

void TtsPcmPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  tts_pcm::TtsPcmPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
