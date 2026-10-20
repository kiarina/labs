#pragma once
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <memory>
namespace playout_audio {
class State;
class PlayoutAudioPlugin : public flutter::Plugin {
 public:
  PlayoutAudioPlugin();
  ~PlayoutAudioPlugin() override;
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);
  void Handle(const flutter::MethodCall<flutter::EncodableValue>& call,
              std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  std::unique_ptr<State> state_;
};
}  // namespace playout_audio
