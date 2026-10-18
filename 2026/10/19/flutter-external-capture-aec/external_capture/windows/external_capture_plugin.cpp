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
#include <cstdint>
#include <vector>

#include "flutter_webrtc.h"

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
  static auto& Streams(flutter_webrtc_plugin::FlutterWebRTCBase* b) {
    return b->*(&Access::local_streams_);
  }
  static auto& Tracks(flutter_webrtc_plugin::FlutterWebRTCBase* b) {
    return b->*(&Access::local_tracks_);
  }
};
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
  scoped_refptr<RTCVideoSource> video;
  scoped_refptr<RTCAudioSource> audio;
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
    audio =
        factory->CreateAudioSource("external-audio", RTCAudioSource::kCustom);
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
  if (call.method_name() == "recordingSdk") {
    const auto sha = ModuleSha256(GetModuleHandleW(L"libwebrtc.dll"));
    if (sha.empty())
      result->Error("sdk_hash_failed",
                    "Cannot hash the loaded libwebrtc module");
    else
      result->Success(EncodableValue(sha));
    return;
  }
  if (call.method_name() == "recordingAudit") {
    auto module = GetModuleHandleW(L"libwebrtc.dll");
    using Audit = uint64_t(__cdecl*)(int);
    auto audit = module ? reinterpret_cast<Audit>(GetProcAddress(
                              module, "ExternalCaptureGetRecordingAudit"))
                        : nullptr;
    if (!audit) {
      result->Error("unsupported_sdk",
                    "The audited lab-only libwebrtc DLL is required");
      return;
    }
    uint64_t values[9]{};
    for (int i = 0; i < 9; ++i) values[i] = audit(i);
    const char* names[] = {"admInitRecording",         "admStartRecording",
                           "windowsInitRecording",     "windowsStartRecording",
                           "wasapiInitialize",         "wasapiCaptureService",
                           "dmoInitRecording",         "peerConnections",
                           "suppressedPeerConnections"};
    EncodableMap snapshot;
    for (int i = 0; i < 9; ++i)
      snapshot[EncodableValue(names[i])] =
          EncodableValue(static_cast<int64_t>(values[i]));
    result->Success(EncodableValue(snapshot));
    return;
  }
  if (call.method_name() == "create" || call.method_name() == "createFar") {
    auto module = GetModuleHandleW(L"libwebrtc.dll");
    if (!module ||
        !GetProcAddress(module, "ExternalCaptureGetRecordingAudit")) {
      result->Error(
          "unsupported_sdk",
          "Windows external capture requires the audited recording-isolated "
          "lab SDK; see patches/windows/build_sdk.ps1");
      return;
    }
    auto& selected = call.method_name() == "createFar" ? far_input_ : input_;
    selected.reset();
    auto base = FlutterWebRTCPluginSharedInstance();
    if (!base) {
      result->Error("not_ready", "Initialize flutter_webrtc first");
      return;
    }
    selected = std::make_unique<Input>(base);
    result->Success(EncodableValue(EncodableMap{
        {EncodableValue("streamId"), EncodableValue(selected->stream_id)},
        {EncodableValue("audioTrackId"), EncodableValue(selected->audio_id)},
        {EncodableValue("videoTrackId"), EncodableValue(selected->video_id)}}));
    return;
  }
  if (call.method_name() == "flush") {
    if (input_) input_->pending.clear();
    result->Success();
    return;
  }
  if (call.method_name() == "dispose") {
    input_.reset();
    far_input_.reset();
    result->Success();
    return;
  }
  auto* target =
      call.method_name() == "pushFarAudio" ? far_input_.get() : input_.get();
  if (!target) {
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
    target->Video(*data, static_cast<int>(w), static_cast<int>(h));
    result->Success();
    return;
  }
  if (call.method_name() == "pushAudio" ||
      call.method_name() == "pushFarAudio") {
    if (data->size() % 2 || data->size() > 192000) {
      result->Error("invalid_input",
                    "Expected PCM16 mono 48kHz, at most 2 seconds");
      return;
    }
    target->Audio(*data);
    result->Success();
    return;
  }
  result->NotImplemented();
}
}  // namespace external_capture
