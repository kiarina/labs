#include "external_capture_plugin.h"

// clang-format off
#include <windows.h>
#include <bcrypt.h>
// clang-format on

#include <flutter/standard_method_codec.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstdint>
#include <vector>

#include "flutter_webrtc.h"
#include "rtc_audio_device.h"
#if defined(UPSTREAM_NATIVE_PLAYOUT_DIAGNOSTIC)
#include "src/rtc_peerconnection_impl.h"
#endif

using flutter::EncodableMap;
using flutter::EncodableValue;
using namespace libwebrtc;
namespace external_capture {
namespace {
// C++ protected pointer-to-member access: no layout cast and no cache edits.
struct Access : flutter_webrtc_plugin::FlutterWebRTCBase {
  static auto Factory(flutter_webrtc_plugin::FlutterWebRTCBase* b) {
    return b->*(&Access::factory_);
  }
  static auto& Connections(flutter_webrtc_plugin::FlutterWebRTCBase* b) {
    return b->*(&Access::peerconnections_);
  }
  static auto& Streams(flutter_webrtc_plugin::FlutterWebRTCBase* b) {
    return b->*(&Access::local_streams_);
  }
  static auto& Tracks(flutter_webrtc_plugin::FlutterWebRTCBase* b) {
    return b->*(&Access::local_tracks_);
  }
};
#if defined(UPSTREAM_NATIVE_PLAYOUT_DIAGNOSTIC)
// Diagnostic only: requires the exact native/wrapper source matching the DLL.
// Calls the ordinary native virtual API; no additional SDK patch, hook or memory write.
struct NativePeerAccess : libwebrtc::RTCPeerConnectionImpl {
  static auto Peer(libwebrtc::RTCPeerConnectionImpl* p) {
    return p->*(&NativePeerAccess::rtc_peerconnection_);
  }
};
#endif
const EncodableValue* Arg(const EncodableMap& a, const char* key) {
  auto it = a.find(EncodableValue(key));
  return it == a.end() ? nullptr : &it->second;
}
int64_t Int(const EncodableMap& a, const char* key) {
  auto v = Arg(a, key);
  if (!v) return 0;
  if (auto i = std::get_if<int32_t>(v)) return *i;
  if (auto i = std::get_if<int64_t>(v)) return *i;
  return 0;
}
uint8_t Clip(int n) { return static_cast<uint8_t>(std::clamp(n, 0, 255)); }
std::string ModuleSha256(HMODULE module) {
  std::vector<wchar_t> path(32768);
  if (!module ||
      !GetModuleFileNameW(module, path.data(), static_cast<DWORD>(path.size())))
    return {};
  HANDLE file =
      CreateFileW(path.data(), GENERIC_READ,
                  FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                  nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) return {};
  BCRYPT_ALG_HANDLE algorithm = nullptr;
  BCRYPT_HASH_HANDLE hash = nullptr;
  DWORD object_size = 0, returned = 0;
  bool ok = BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                        nullptr, 0) >= 0;
  if (ok)
    ok = BCryptGetProperty(algorithm, BCRYPT_OBJECT_LENGTH,
                           reinterpret_cast<PUCHAR>(&object_size),
                           sizeof(object_size), &returned, 0) >= 0;
  std::vector<UCHAR> object(object_size), chunk(65536);
  if (ok)
    ok = BCryptCreateHash(algorithm, &hash, object.data(), object_size, nullptr,
                          0, 0) >= 0;
  DWORD count = 0;
  while (ok) {
    if (!ReadFile(file, chunk.data(), static_cast<DWORD>(chunk.size()), &count,
                  nullptr)) {
      ok = false;
      break;
    }
    if (!count) break;
    ok = BCryptHashData(hash, chunk.data(), count, 0) >= 0;
  }
  UCHAR digest[32]{};
  if (ok) ok = BCryptFinishHash(hash, digest, sizeof(digest), 0) >= 0;
  if (hash) BCryptDestroyHash(hash);
  if (algorithm) BCryptCloseAlgorithmProvider(algorithm, 0);
  CloseHandle(file);
  if (!ok) return {};
  constexpr char hex[] = "0123456789abcdef";
  std::string result;
  for (auto byte : digest) {
    result += hex[byte >> 4];
    result += hex[byte & 15];
  }
  return result;
}

}  // namespace
class Input {
 public:
  flutter_webrtc_plugin::FlutterWebRTCBase* base;
  std::string stream_id, video_id, audio_id;
  libwebrtc::scoped_refptr<RTCVideoSource> video;
  libwebrtc::scoped_refptr<RTCAudioSource> audio;
  std::vector<uint8_t> pending;
  explicit Input(flutter_webrtc_plugin::FlutterWebRTCBase* b) : base(b) {
    auto factory = Access::Factory(base);
    static std::atomic<uint64_t> sequence{0};
    const auto seed =
        std::chrono::steady_clock::now().time_since_epoch().count();
    stream_id =
        "external-" + std::to_string(seed) + "-" + std::to_string(++sequence);
    video_id = stream_id + "-video";
    audio_id = stream_id + "-audio";
    auto constraints = RTCMediaConstraints::Create();
    video = factory->CreateCustomVideoSource("external-video", constraints);
    RTCAudioOptions options;
    char processing_off[4]{};
    if(GetEnvironmentVariableA("UPSTREAM_AUDIO_PROCESSING_OFF",processing_off,4)==1 && processing_off[0]=='1') {
      options.echo_cancellation=false;
      options.auto_gain_control=false;
      options.noise_suppression=false;
      options.highpass_filter=false;
    }
    audio = factory->CreateAudioSource("external-audio", RTCAudioSource::kCustom, options);
    auto vt = factory->CreateVideoTrack(video, video_id.c_str());
    auto at = factory->CreateAudioTrack(audio, audio_id.c_str());
    auto stream = factory->CreateStream(stream_id.c_str());
    stream->AddTrack(vt);
    stream->AddTrack(at);
    Access::Streams(base)[stream_id] = stream;
    Access::Tracks(base)[video_id] = vt;
    Access::Tracks(base)[audio_id] = at;
  }
  ~Input() {
    Access::Tracks(base).erase(video_id);
    Access::Tracks(base).erase(audio_id);
    Access::Streams(base).erase(stream_id);
  }
  void Video(const std::vector<uint8_t>& bgra, int w, int h) {
    const int cw = (w + 1) / 2, ch = (h + 1) / 2;
    std::vector<uint8_t> y(static_cast<size_t>(w) * h),
        u(static_cast<size_t>(cw) * ch), v(u.size());
    for (int row = 0; row < h; ++row)
      for (int col = 0; col < w; ++col) {
        const auto p = &bgra[(static_cast<size_t>(row) * w + col) * 4];
        y[static_cast<size_t>(row) * w + col] =
            Clip(((66 * p[2] + 129 * p[1] + 25 * p[0] + 128) >> 8) + 16);
      }
    for (int row = 0; row < h; row += 2)
      for (int col = 0; col < w; col += 2) {
        int r = 0, g = 0, b = 0, n = 0;
        for (int dy = 0; dy < 2 && row + dy < h; ++dy)
          for (int dx = 0; dx < 2 && col + dx < w; ++dx) {
            const auto p =
                &bgra[(static_cast<size_t>(row + dy) * w + col + dx) * 4];
            b += p[0];
            g += p[1];
            r += p[2];
            ++n;
          }
        r /= n;
        g /= n;
        b /= n;
        const auto pos = static_cast<size_t>(row / 2) * cw + col / 2;
        u[pos] = Clip(((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128);
        v[pos] = Clip(((112 * r - 94 * g - 18 * b + 128) >> 8) + 128);
      }
    auto frame =
        RTCVideoFrame::Create(w, h, y.data(), w, u.data(), cw, v.data(), cw);
    video->OnCapturedFrame(frame);
  }
  void Audio(const std::vector<uint8_t>& bytes) {
    pending.insert(pending.end(), bytes.begin(), bytes.end());
    size_t offset = 0;
    while (pending.size() - offset >= 960) {
      // Aligned PCM16 and exact 10 ms chunks for the WebRTC audio sink.
      int16_t samples[480];
      for (size_t i = 0; i < 480; ++i)
        samples[i] = static_cast<int16_t>(pending[offset + i * 2] |
                                          (pending[offset + i * 2 + 1] << 8));
      audio->CaptureFrame(samples, 16, 48000, 1, 480);
      offset += 960;
    }
    pending.erase(pending.begin(), pending.begin() + offset);
  }
};
ExternalCapturePlugin::ExternalCapturePlugin() = default;
ExternalCapturePlugin::~ExternalCapturePlugin() = default;
void ExternalCapturePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "external_capture",
      &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<ExternalCapturePlugin>();
  channel->SetMethodCallHandler(
      [p = plugin.get()](const auto& call, auto result) {
        p->HandleMethodCall(call, std::move(result));
      });
  registrar->AddPlugin(std::move(plugin));
}
void ExternalCapturePlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() == "disableNativePlayoutDiagnostic") {
#if defined(UPSTREAM_NATIVE_PLAYOUT_DIAGNOSTIC)
    auto base = FlutterWebRTCPluginSharedInstance();
    if (!base) { result->Error("not_ready", "Initialize factory first"); return; }
    int count = 0;
    for (const auto& entry : Access::Connections(base)) {
      auto* impl = static_cast<libwebrtc::RTCPeerConnectionImpl*>(entry.second.get());
      auto peer = NativePeerAccess::Peer(impl);
      if (!peer) { result->Error("not_ready", "Native peer missing"); return; }
      peer->SetAudioPlayout(false);
      ++count;
    }
    result->Success(EncodableValue(EncodableMap{
      {EncodableValue("connections"), EncodableValue(count)},
      {EncodableValue("nativeAudioPlayout"), EncodableValue(false)},
      {EncodableValue("scope"), EncodableValue("source-matched internals for diagnosis; standard native SetAudioPlayout(false)/NullAudioPoller")}
    }));
#else
    result->Error("diagnostic_unavailable", "Build with matching LAB_NATIVE_SOURCE");
#endif
    return;
  }
  if (call.method_name() == "selectPlayout") {
    auto base=FlutterWebRTCPluginSharedInstance();
    if(!base){result->Error("not_ready","Initialize factory first");return;}
    auto device=Access::Factory(base)->GetAudioDevice();
    char wanted[128]{};GetEnvironmentVariableA("UPSTREAM_SPEAKER",wanted,128);
    const std::string match=wanted[0]?wanted:"EDIFIER";
    int selected=-1;std::string label;flutter::EncodableList labels;
    for(int i=0;i<device->PlayoutDevices();++i){
      char name[RTCAudioDevice::kAdmMaxDeviceNameSize]{},guid[RTCAudioDevice::kAdmMaxGuidSize]{};
      if(device->PlayoutDeviceName(static_cast<uint16_t>(i),name,guid)==0){labels.emplace_back(std::string(name));if(std::string(name).find(match)!=std::string::npos){selected=i;label=name;}}
    }
    const int status=selected>=0?device->SetPlayoutDevice(static_cast<uint16_t>(selected)):-100;
    result->Success(EncodableValue(EncodableMap{
      {EncodableValue("selectedIndex"),EncodableValue(selected)},
      {EncodableValue("selectedLabel"),EncodableValue(label)},
      {EncodableValue("status"),EncodableValue(status)},
      {EncodableValue("available"),EncodableValue(labels)}
    }));return;
  }
  if (call.method_name() == "candidateIdentity") {
    auto module=GetModuleHandleW(L"libwebrtc.dll");
    result->Success(EncodableValue(EncodableMap{
      {EncodableValue("sha256"),EncodableValue(ModuleSha256(module))},
      {EncodableValue("customRecordingAuditExportPresent"),EncodableValue(module && GetProcAddress(module,"ExternalCaptureGetRecordingAudit"))},
      {EncodableValue("customPlayoutExportPresent"),EncodableValue(module && GetProcAddress(module,"LabPullPlayout"))},
      {EncodableValue("recordingAudit"),EncodableValue("unavailable in candidate SDK; external observation required")}
    }));
    return;
  }
  if (call.method_name() == "create") {
    auto module=GetModuleHandleW(L"libwebrtc.dll");
    char expected[65]{};
    const DWORD expected_length=GetEnvironmentVariableA("UPSTREAM_EXPECTED_SHA256",expected,65);
    if(!module || expected_length!=64 || ModuleSha256(module)!=expected || GetProcAddress(module,"ExternalCaptureGetRecordingAudit") || GetProcAddress(module,"LabPullPlayout")) {
      result->Error("candidate_identity_mismatch","Expected pinned candidate DLL hash and no lab-specific exports");return;
    }
    input_.reset();
    auto base = FlutterWebRTCPluginSharedInstance();
    if (!base) {
      result->Error("not_ready", "Initialize flutter_webrtc first");
      return;
    }
    input_ = std::make_unique<Input>(base);
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("streamId"), EncodableValue(input_->stream_id)},
        {EncodableValue("audioTrackId"), EncodableValue(input_->audio_id)},
        {EncodableValue("videoTrackId"), EncodableValue(input_->video_id)}}));
    return;
  }
  if (call.method_name() == "flush") {
    if (input_) input_->pending.clear();
    result->Success();
    return;
  }
  if (call.method_name() == "dispose") {
    input_.reset();
    result->Success();
    return;
  }
  if (!input_) {
    result->Error("not_ready", "create must precede input");
    return;
  }
  const auto args =
      call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
  auto bytes = args ? Arg(*args, "bytes") : nullptr;
  auto data = bytes ? std::get_if<std::vector<uint8_t>>(bytes) : nullptr;
  if (!data) {
    result->Error("invalid_input", "bytes must be Uint8List");
    return;
  }
  if (call.method_name() == "pushVideo") {
    auto w = Int(*args, "width"), h = Int(*args, "height");
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096 ||
        data->size() != static_cast<size_t>(w * h * 4)) {
      result->Error("invalid_input", "Expected packed BGRA, dimensions <=4096");
      return;
    }
    input_->Video(*data, static_cast<int>(w), static_cast<int>(h));
    result->Success();
    return;
  }
  if (call.method_name() == "pushAudio") {
    if (data->size() % 2 || data->size() > 192000) {
      result->Error("invalid_input",
                    "Expected PCM16 mono 48kHz, at most 2 seconds");
      return;
    }
    input_->Audio(*data);
    result->Success();
    return;
  }
  result->NotImplemented();
}
}  // namespace external_capture
