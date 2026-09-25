#ifndef FLUTTER_PLUGIN_MEDIA_TAPS_PLUGIN_H_
#define FLUTTER_PLUGIN_MEDIA_TAPS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <map>
#include <memory>

namespace media_taps {

class Tap;

class MediaTapsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  MediaTapsPlugin();
  virtual ~MediaTapsPlugin();

  MediaTapsPlugin(const MediaTapsPlugin &) = delete;
  MediaTapsPlugin &operator=(const MediaTapsPlugin &) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  std::map<int, std::unique_ptr<Tap>> taps_;
  int next_id_ = 1;
};

}  // namespace media_taps

#endif  // FLUTTER_PLUGIN_MEDIA_TAPS_PLUGIN_H_
