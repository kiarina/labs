#ifndef FLUTTER_PLUGIN_TTS_PCM_PLUGIN_H_
#define FLUTTER_PLUGIN_TTS_PCM_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <string>

namespace tts_pcm {

// Method channel `tts_pcm`. Windows.Media.SpeechSynthesis renders a whole
// utterance into one WAV stream, so each request yields a single chunk.
// Synthesis runs on a worker thread; results are posted back to the window
// procedure because the channel may only be used on the platform thread.
class TtsPcmPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  TtsPcmPlugin(flutter::PluginRegistrarWindows* registrar,
               std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel);
  virtual ~TtsPcmPlugin();

  TtsPcmPlugin(const TtsPcmPlugin&) = delete;
  TtsPcmPlugin& operator=(const TtsPcmPlugin&) = delete;

 private:
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  std::optional<LRESULT> HandleWindowProc(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam);

  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  int window_proc_id_ = -1;
  std::mutex mutex_;
  std::set<std::string> running_;
};

}  // namespace tts_pcm

#endif  // FLUTTER_PLUGIN_TTS_PCM_PLUGIN_H_
