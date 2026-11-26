//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <audioplayers_windows/audioplayers_windows_plugin.h>
#include <flutter_js/flutter_js_plugin.h>
#include <video_player_win/video_player_win_plugin_c_api.h>
#include <webview_all_windows/webview_all_windows_plugin.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  AudioplayersWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("AudioplayersWindowsPlugin"));
  FlutterJsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterJsPlugin"));
  VideoPlayerWinPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("VideoPlayerWinPluginCApi"));
  WebviewAllWindowsPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("WebviewAllWindowsPlugin"));
}
