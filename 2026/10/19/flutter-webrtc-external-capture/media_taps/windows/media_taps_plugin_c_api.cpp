#include "include/media_taps/media_taps_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "media_taps_plugin.h"

void MediaTapsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  media_taps::MediaTapsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
