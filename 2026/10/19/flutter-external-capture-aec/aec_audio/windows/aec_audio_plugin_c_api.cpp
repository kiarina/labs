#include "include/aec_audio/aec_audio_plugin_c_api.h"

#include "aec_audio_plugin.h"
void AecAudioPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  aec_audio::AecAudioPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
