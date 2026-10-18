//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <aec_audio/aec_audio_plugin_c_api.h>
#include <camera_desktop/camera_desktop_plugin.h>
#include <external_capture/external_capture_plugin_c_api.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>
#include <media_taps/media_taps_plugin_c_api.h>
#include <record_windows/record_windows_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  AecAudioPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AecAudioPluginCApi"));
  CameraDesktopPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("CameraDesktopPlugin"));
  ExternalCapturePluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("ExternalCapturePluginCApi"));
  FlutterWebRTCPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterWebRTCPlugin"));
  MediaTapsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("MediaTapsPluginCApi"));
  RecordWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("RecordWindowsPluginCApi"));
}
