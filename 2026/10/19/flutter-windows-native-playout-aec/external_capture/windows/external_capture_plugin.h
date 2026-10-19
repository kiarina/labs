#ifndef FLUTTER_PLUGIN_EXTERNAL_CAPTURE_PLUGIN_H_
#define FLUTTER_PLUGIN_EXTERNAL_CAPTURE_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <map>
#include <memory>

namespace external_capture {

class Input;

class ExternalCapturePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  ExternalCapturePlugin();
  virtual ~ExternalCapturePlugin();

  ExternalCapturePlugin(const ExternalCapturePlugin&) = delete;
  ExternalCapturePlugin& operator=(const ExternalCapturePlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  std::unique_ptr<Input> input_;
};

}  // namespace external_capture

#endif  // FLUTTER_PLUGIN_EXTERNAL_CAPTURE_PLUGIN_H_
