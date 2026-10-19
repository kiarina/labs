#include "include/external_capture/external_capture_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "external_capture_plugin.h"

void ExternalCapturePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  external_capture::ExternalCapturePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
