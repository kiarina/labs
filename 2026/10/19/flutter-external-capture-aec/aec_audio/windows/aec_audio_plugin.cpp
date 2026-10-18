#include "aec_audio_plugin.h"
// clang-format off
#include <windows.h>
// clang-format on
#include <flutter/standard_method_codec.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>

#include <atomic>
#include <mutex>
#include <vector>

#include "aec_engine.h"
#include "flutter_webrtc.h"
#include "windows_playout.h"
using flutter::EncodableMap;
using flutter::EncodableValue;
namespace aec_audio {
namespace {
struct Access : flutter_webrtc_plugin::FlutterWebRTCBase {
  static auto Factory(flutter_webrtc_plugin::FlutterWebRTCBase* b) {
    return b->*(&Access::factory_);
  }
};
const EncodableValue* Arg(const EncodableMap& a, const char* key) {
  auto it = a.find(EncodableValue(key));
  return it == a.end() ? nullptr : &it->second;
}
int Number(const EncodableMap& a, const char* key, int fallback) {
  auto v = Arg(a, key);
  if (!v) return fallback;
  if (auto n = std::get_if<int32_t>(v)) return *n;
  return fallback;
}
bool Flag(const EncodableMap& a, const char* key, bool fallback = false) {
  auto v = Arg(a, key);
  return v && std::holds_alternative<bool>(*v) ? std::get<bool>(*v) : fallback;
}
std::vector<int16_t> Pcm(const std::vector<uint8_t>& bytes) {
  std::vector<int16_t> p(bytes.size() / 2);
  for (size_t i = 0; i < p.size(); ++i)
    p[i] = static_cast<int16_t>(bytes[i * 2] | (bytes[i * 2 + 1] << 8));
  return p;
}
EncodableValue Counter(uint64_t n) {
  return EncodableValue(static_cast<int64_t>(n));
}
}  // namespace
class State {
 public:
  external_aec::WindowsPlayout speaker;
  void* engine = nullptr;
  bool enabled = false;
  int delay = 0;
  uint64_t capture_bytes = 0, output_bytes = 0, render_queued_bytes = 0;
  std::atomic<uint64_t> reverse_frames{0}, native_pulls{0}, dsp_errors{0};
  std::atomic<bool> native_output{false};
  libwebrtc::scoped_refptr<libwebrtc::RTCPeerConnectionFactory> factory;
  using Pull = int(__cdecl*)(void*, int16_t*, int);
  Pull sdk_pull = nullptr;
  std::vector<int16_t> pending;
  std::mutex trace_mutex;
  std::vector<uint8_t> trace;
  bool trace_overflow = false;
  ~State() { Dispose(); }
  void Dispose() {
    speaker.Stop();
    if (engine) {
      aec_destroy(engine);
      engine = nullptr;
    }
    pending.clear();
    factory = nullptr;
    sdk_pull = nullptr;
  }
  bool BindFactory() {
    auto base = FlutterWebRTCPluginSharedInstance();
    if (!base) return false;
    factory = Access::Factory(base);
    auto module = GetModuleHandleW(L"libwebrtc.dll");
    sdk_pull =
        module
            ? reinterpret_cast<Pull>(GetProcAddress(module, "LabPullPlayout"))
            : nullptr;
    return factory && sdk_pull;
  }
  EncodableMap Stats() {
    const auto s = speaker.Stats();
    std::lock_guard<std::mutex> trace_lock(trace_mutex);
    EncodableMap m{
        {EncodableValue("renderBytes"), Counter(s.rendered_blocks * 960)},
        {EncodableValue("captureBytes"), Counter(capture_bytes)},
        {EncodableValue("outputBytes"), Counter(output_bytes)},
        {EncodableValue("queuedRenderBytes"), Counter(render_queued_bytes)},
        {EncodableValue("playbackHeadFrames"), Counter(s.played_frames)},
        {EncodableValue("reverseFrames"), Counter(reverse_frames.load())},
        {EncodableValue("speakerSilenceBlocks"), Counter(s.silence_blocks)},
        {EncodableValue("speakerDiscardedSamples"),
         Counter(s.discarded_samples)},
        {EncodableValue("nativePlayoutPulls"), Counter(native_pulls.load())},
        {EncodableValue("nativePlayoutFailures"), Counter(s.pull_failures)},
        {EncodableValue("dspErrors"), Counter(dsp_errors.load())},
        {EncodableValue("speakerSampleRate"), EncodableValue(s.sample_rate)},
        {EncodableValue("speakerChannels"), EncodableValue(s.channels)},
        {EncodableValue("speakerBits"), EncodableValue(s.bits)},
        {EncodableValue("speakerFloat"), EncodableValue(s.floating_point)},
        {EncodableValue("speakerBufferFrames"),
         EncodableValue(s.buffer_frames)},
        {EncodableValue("speakerLatencyMs"), EncodableValue(s.latency_ms)},
        {EncodableValue("speakerDevice"), EncodableValue(s.device_name)},
        {EncodableValue("speakerError"), EncodableValue(s.error)},
        {EncodableValue("delayMs"), EncodableValue(delay)},
        {EncodableValue("nativePlayoutEnabled"),
         EncodableValue(native_output.load())},
        {EncodableValue("captureBackend"),
         EncodableValue(
             "record; WASAPI backend creates IAudioRenderClient only")}};
    m[EncodableValue("speakerWrittenBytes")] = Counter(s.rendered_blocks * 960);
    m[EncodableValue("renderTraceBytes")] = Counter(trace.size());
    m[EncodableValue("renderTraceOverflow")] = EncodableValue(trace_overflow);
    m[EncodableValue("renderFirstClockUs")] = Counter(s.first_render_us);
    m[EncodableValue("renderLastClockUs")] = Counter(s.last_render_us);
    m[EncodableValue("renderDeviceClockFrequency")] =
        Counter(s.clock_frequency);
    using Audit = uint64_t(__cdecl*)(int);
    auto module = GetModuleHandleW(L"libwebrtc.dll");
    auto audit = module ? reinterpret_cast<Audit>(GetProcAddress(
                              module, "ExternalCaptureGetRecordingAudit"))
                        : nullptr;
    if (audit) {
      const char* keys[] = {"admInitRecording",         "admStartRecording",
                            "windowsInitRecording",     "windowsStartRecording",
                            "wasapiInitialize",         "wasapiCaptureService",
                            "dmoInitRecording",         "peerConnections",
                            "suppressedPeerConnections"};
      EncodableMap counters;
      for (int i = 0; i < 9; ++i)
        counters[EncodableValue(keys[i])] = Counter(audit(i));
      m[EncodableValue("recordingAudit")] = EncodableValue(counters);
    } else
      m[EncodableValue("recordingAuditError")] =
          EncodableValue("Audited transport SDK required");
    return m;
  }
};
AecAudioPlugin::AecAudioPlugin() : state_(std::make_unique<State>()) {}
AecAudioPlugin::~AecAudioPlugin() = default;
void AecAudioPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "aec_audio",
      &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<AecAudioPlugin>();
  channel->SetMethodCallHandler([p = plugin.get()](const auto& c, auto r) {
    p->Handle(c, std::move(r));
  });
  registrar->AddPlugin(std::move(plugin));
}
void AecAudioPlugin::Handle(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const EncodableMap empty;
  const auto args =
      call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
  const auto& a = args ? *args : empty;
  auto& s = *state_;
  if (call.method_name() == "renderTrace") {
    std::lock_guard<std::mutex> lock(s.trace_mutex);
    if (s.trace_overflow)
      result->Error("aec_audio", "Actual render trace exceeded 120 seconds");
    else
      result->Success(EncodableValue(s.trace));
    return;
  }
  if (call.method_name() == "configure") {
    s.Dispose();
    s.enabled = Flag(a, "enabled");
    s.delay = Number(a, "delayMs", 0);
    if (s.delay < 0 || s.delay > 1000) {
      result->Error("aec_audio", "delayMs must be 0..1000");
      return;
    }
    {
      std::lock_guard<std::mutex> lock(s.trace_mutex);
      s.trace.clear();
      s.trace.reserve(120 * 96000);
      s.trace_overflow = false;
    }
    s.engine = aec_create(s.enabled ? 1 : 0);
    if (!s.engine) {
      result->Error("aec_audio", "AEC create failed");
      return;
    }
    s.capture_bytes = s.output_bytes = s.render_queued_bytes = 0;
    s.reverse_frames = 0;
    s.native_pulls = 0;
    s.dsp_errors = 0;
    s.native_output = Flag(a, "nativePlayout");
    const bool bound = s.BindFactory();
    if (s.native_output && !bound) {
      s.Dispose();
      result->Error("aec_audio",
                    "Initialize WebRTC with the manual-playout lab SDK first");
      return;
    }
    auto reference = [&s](const external_aec::WindowsPlayout::Block& pcm) {
      if (aec_reverse(s.engine, pcm.data(), 480) != 0) ++s.dsp_errors;
      ++s.reverse_frames;
      std::lock_guard<std::mutex> lock(s.trace_mutex);
      if (s.trace.size() + 960 <= 120 * 96000) {
        for (const auto value : pcm) {
          s.trace.push_back(static_cast<uint8_t>(value & 255));
          s.trace.push_back(
              static_cast<uint8_t>((static_cast<uint16_t>(value) >> 8) & 255));
        }
      } else
        s.trace_overflow = true;
    };
    external_aec::WindowsPlayout::Pull pull;
    if (bound)
      pull = [&s](external_aec::WindowsPlayout::Block& pcm) {
        ++s.native_pulls;
        const bool ok = s.sdk_pull(s.factory.get(), pcm.data(), 480) == 480;
        if (!s.native_output) pcm.fill(0);
        return ok;
      };
    double gain = 1.0;
    if (auto v = Arg(a, "gain")) {
      if (auto n = std::get_if<double>(v)) gain = *n;
    }
    if (!s.speaker.Start(reference, pull, gain)) {
      const auto error = s.speaker.Stats().error;
      s.Dispose();
      result->Error("aec_audio", error);
      return;
    }
    result->Success();
    return;
  }
  if (call.method_name() == "dispose") {
    s.Dispose();
    result->Success();
    return;
  }
  if (call.method_name() == "stats") {
    result->Success(EncodableValue(s.Stats()));
    return;
  }
  if (!s.engine) {
    result->Error("aec_audio", "configure first");
    return;
  }
  if (call.method_name() == "stopRender") {
    s.speaker.Flush();
    s.native_output = false;
    result->Success();
    return;
  }
  if (call.method_name() == "reset") {
    aec_reset(s.engine);
    s.pending.clear();
    result->Success();
    return;
  }
  if (call.method_name() == "setNativePlayout") {
    if (!s.factory || !s.sdk_pull) {
      result->Error(
          "aec_audio",
          "Reconfigure after WebRTC initialization with manual-playout SDK");
      return;
    }
    s.native_output = Flag(a, "enabled");
    result->Success();
    return;
  }
  const auto v = Arg(a, "bytes");
  const auto bytes = v ? std::get_if<std::vector<uint8_t>>(v) : nullptr;
  if (!bytes || bytes->size() % 2 || bytes->size() > 192000) {
    result->Error("aec_audio",
                  "Expected at most 2 seconds of PCM16 mono 48kHz");
    return;
  }
  auto pcm = Pcm(*bytes);
  if (call.method_name() == "render") {
    s.speaker.Enqueue(pcm.data(), pcm.size());
    s.render_queued_bytes += bytes->size();
    result->Success();
    return;
  }
  if (call.method_name() == "capture") {
    s.capture_bytes += bytes->size();
    s.pending.insert(s.pending.end(), pcm.begin(), pcm.end());
    std::vector<uint8_t> output;
    size_t offset = 0;
    while (s.pending.size() - offset >= 480) {
      int16_t block[480];
      if (aec_capture(s.engine, s.pending.data() + offset, block, 480,
                      s.delay) != 0) {
        result->Error("aec_audio", "AEC capture processing failed");
        ++s.dsp_errors;
        return;
      }
      for (auto value : block) {
        output.push_back(static_cast<uint8_t>(value & 255));
        output.push_back(
            static_cast<uint8_t>((static_cast<uint16_t>(value) >> 8) & 255));
      }
      offset += 480;
    }
    s.pending.erase(s.pending.begin(), s.pending.begin() + offset);
    s.output_bytes += output.size();
    result->Success(EncodableValue(output));
    return;
  }
  result->NotImplemented();
}
}  // namespace aec_audio
