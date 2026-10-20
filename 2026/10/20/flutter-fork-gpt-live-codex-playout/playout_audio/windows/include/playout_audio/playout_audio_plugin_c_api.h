#pragma once
#include <flutter_plugin_registrar.h>
#ifdef FLUTTER_PLUGIN_IMPL
#define PLAYOUT_PLUGIN_EXPORT __declspec(dllexport)
#else
#define PLAYOUT_PLUGIN_EXPORT __declspec(dllimport)
#endif
#ifdef __cplusplus
extern "C" {
#endif
PLAYOUT_PLUGIN_EXPORT void PlayoutAudioPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);
#ifdef __cplusplus
}
#endif
