//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <ffmpeg_kit_flutter_new_min/f_fmpeg_kit_flutter_plugin.h>
#include <flutter_onnxruntime/flutter_onnxruntime_plugin.h>
#include <record_windows/record_windows_plugin_c_api.h>

void RegisterPlugins(flutter::PluginRegistry* registry) {
  FFmpegKitFlutterPluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FFmpegKitFlutterPlugin"));
  FlutterOnnxruntimePluginRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("FlutterOnnxruntimePlugin"));
  RecordWindowsPluginCApiRegisterWithRegistrar(
      registry->GetRegistrarForPlugin("RecordWindowsPluginCApi"));
}
