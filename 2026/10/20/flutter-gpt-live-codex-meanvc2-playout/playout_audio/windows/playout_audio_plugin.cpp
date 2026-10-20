#include "playout_audio_plugin.h"

#include <windows.h>
#include <audioclient.h>
#include <avrt.h>
#include <mmdeviceapi.h>
#include <mmreg.h>
#include <ksmedia.h>
#include <wrl/client.h>
#include <flutter/standard_method_codec.h>
#include <flutter_webrtc/flutter_web_r_t_c_plugin.h>

#include <algorithm>
#include <atomic>
#include <cstring>
#include <future>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "flutter_webrtc.h"
#include "playout_pipeline.h"

// Taps the decoded remote track (AddSink, before the mixer gain), mutes the
// native SDK playout with SetVolume(0) (native playout keeps running on the
// selected endpoint and drives decoding), and renders the slot output with an
// application-owned shared-mode WASAPI client on the same endpoint. The PCM
// handed to WASAPI is the AEC reference.
using Microsoft::WRL::ComPtr;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace playout_audio {
namespace {
struct Access : flutter_webrtc_plugin::FlutterWebRTCBase {
  static auto& Peers(flutter_webrtc_plugin::FlutterWebRTCBase* b) { return b->*(&Access::peerconnections_); }
};
const EncodableValue* Arg(const EncodableMap& a, const char* key) {
  auto i = a.find(EncodableValue(key));
  return i == a.end() ? nullptr : &i->second;
}
int Number(const EncodableMap& a, const char* key, int fallback) {
  auto v = Arg(a, key);
  return v && std::holds_alternative<int32_t>(*v) ? std::get<int32_t>(*v) : fallback;
}
EncodableValue I(int64_t v) { return EncodableValue(v); }
std::vector<uint8_t> Bytes(const int16_t* p, size_t n) {
  std::vector<uint8_t> b(n * 2);
  std::memcpy(b.data(), p, n * 2);
  return b;
}
}  // namespace

class Sink : public libwebrtc::AudioTrackSink {
 public:
  std::mutex lock;
  void* pipeline = nullptr;
  std::atomic<int64_t> callbacks{0}, non16{0};
  void OnData(const void* data, int bits, int rate, size_t channels, size_t frames) override {
    std::lock_guard<std::mutex> g(lock);
    if (!pipeline) return;
    if (bits != 16) {
      ++non16;
      return;
    }
    pipeline_received(pipeline, static_cast<const int16_t*>(data), static_cast<int>(frames),
                      static_cast<int>(channels), rate);
    ++callbacks;
  }
};

class State {
 public:
  void* pipeline = nullptr;
  std::string endpoint;
  libwebrtc::scoped_refptr<libwebrtc::RTCAudioTrack> track;
  Sink sink;
  std::thread thread;
  std::atomic<bool> stop{false};
  std::atomic<int64_t> hresult{0}, mix_rate{0}, mix_channels{0}, buffer_frames{0}, render_calls{0}, glitches{0};
  ~State() { Dispose(); }

  void Detach() {
    if (track) track->RemoveSink(&sink);
    {
      std::lock_guard<std::mutex> g(sink.lock);
      sink.pipeline = nullptr;
    }
    stop = true;
    if (thread.joinable()) thread.join();
    track = nullptr;
  }
  void Dispose() {
    Detach();
    if (pipeline) pipeline_destroy(pipeline);
    pipeline = nullptr;
  }

  HRESULT StartRender() {
    stop = false;
    auto ready = std::make_shared<std::promise<HRESULT>>();
    auto future = ready->get_future();
    thread = std::thread([this, ready] { Loop(ready); });
    return future.get();
  }

  void Loop(std::shared_ptr<std::promise<HRESULT>> ready) {
    HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    if (FAILED(hr)) {
      hresult = hr;
      ready->set_value(hr);
      return;
    }
    bool signalled = false;
    auto run = [&]() -> HRESULT {
      ComPtr<IMMDeviceEnumerator> enumerator;
      ComPtr<IMMDevice> device;
      ComPtr<IAudioClient> client;
      ComPtr<IAudioRenderClient> render;
      HRESULT r = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL, IID_PPV_ARGS(&enumerator));
      if (FAILED(r)) return r;
      int n = MultiByteToWideChar(CP_UTF8, 0, endpoint.data(), static_cast<int>(endpoint.size()), nullptr, 0);
      std::wstring id(n, L'\0');
      MultiByteToWideChar(CP_UTF8, 0, endpoint.data(), static_cast<int>(endpoint.size()), id.data(), n);
      r = endpoint.empty() ? enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device) : enumerator->GetDevice(id.c_str(), &device);
      if (FAILED(r)) return r;
      r = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr, reinterpret_cast<void**>(client.GetAddressOf()));
      if (FAILED(r)) return r;
      WAVEFORMATEX* mix = nullptr;
      r = client->GetMixFormat(&mix);
      if (FAILED(r)) return r;
      mix_rate = mix->nSamplesPerSec;
      const WORD channels = mix->nChannels;
      mix_channels = channels;
      CoTaskMemFree(mix);
      // Our stream is 48 kHz float with the endpoint's channel count; the
      // engine converts the rate if the endpoint mix rate differs.
      WAVEFORMATEXTENSIBLE fmt{};
      fmt.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
      fmt.Format.nChannels = channels;
      fmt.Format.nSamplesPerSec = 48000;
      fmt.Format.wBitsPerSample = 32;
      fmt.Format.nBlockAlign = channels * 4;
      fmt.Format.nAvgBytesPerSec = 48000 * fmt.Format.nBlockAlign;
      fmt.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
      fmt.Samples.wValidBitsPerSample = 32;
      fmt.dwChannelMask = channels == 1 ? SPEAKER_FRONT_CENTER : SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT;
      fmt.SubFormat = KSDATAFORMAT_SUBTYPE_IEEE_FLOAT;
      r = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                             AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM |
                                 AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
                             200000, 0, &fmt.Format, nullptr);
      if (FAILED(r)) return r;
      HANDLE event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
      client->SetEventHandle(event);
      UINT32 frames = 0;
      client->GetBufferSize(&frames);
      buffer_frames = frames;
      r = client->GetService(IID_PPV_ARGS(&render));
      if (FAILED(r)) return r;
      std::vector<int16_t> mono(frames);
      DWORD task = 0;
      HANDLE mmcss = AvSetMmThreadCharacteristicsW(L"Pro Audio", &task);
      r = client->Start();
      if (FAILED(r)) return r;
      signalled = true;
      ready->set_value(S_OK);
      while (!stop) {
        if (WaitForSingleObject(event, 200) != WAIT_OBJECT_0) {
          ++glitches;
          continue;
        }
        UINT32 padding = 0;
        if (FAILED(client->GetCurrentPadding(&padding))) break;
        const UINT32 avail = frames - padding;
        if (!avail) continue;
        BYTE* data = nullptr;
        if (FAILED(render->GetBuffer(avail, &data))) break;
        pipeline_render(pipeline, mono.data(), static_cast<int>(avail));
        float* out = reinterpret_cast<float*>(data);
        for (UINT32 f = 0; f < avail; ++f)
          for (WORD c = 0; c < channels; ++c) out[f * channels + c] = mono[f] / 32768.f;
        render->ReleaseBuffer(avail, 0);
        ++render_calls;
      }
      client->Stop();
      if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
      CloseHandle(event);
      return S_OK;
    };
    hr = run();
    hresult = hr;
    if (!signalled) ready->set_value(hr);
    CoUninitialize();
  }

  EncodableMap Stats() {
    EncodableMap m;
    if (pipeline) {
      pipeline_stats s;
      pipeline_stats_get(pipeline, &s);
      m = {{EncodableValue("receivedFrames"), I(s.received_frames)}, {EncodableValue("receivedRate"), I(s.received_rate)},
           {EncodableValue("receivedChannels"), I(s.received_channels)}, {EncodableValue("slotBlocks"), I(s.slot_blocks)},
           {EncodableValue("playedSamples"), I(s.played_samples)}, {EncodableValue("underflowSamples"), I(s.underflow_samples)},
           {EncodableValue("overflowSamples"), I(s.overflow_samples)}, {EncodableValue("referenceBlocks"), I(s.reference_blocks)},
           {EncodableValue("controlReferenceBlocks"), I(s.control_reference_blocks)},
           {EncodableValue("captureSamples"), I(s.capture_samples)}, {EncodableValue("dspErrors"), I(s.dsp_errors)},
           {EncodableValue("traceDroppedSamples"), I(s.trace_dropped_samples)}, {EncodableValue("queuedSamples"), I(s.queued_samples)},
           {EncodableValue("slotMode"), I(s.slot_mode)}, {EncodableValue("slotLatencySamples"), I(s.slot_latency_samples)},
           {EncodableValue("primed"), I(s.primed)},
           {EncodableValue("externalPendingSamples"), I(s.external_pending_samples)},
           {EncodableValue("externalReturnedSamples"), I(s.external_returned_samples)},
           {EncodableValue("externalPulledSamples"), I(s.external_pulled_samples)},
           {EncodableValue("externalMaxPendingSamples"), I(s.external_max_pending_samples)},
           {EncodableValue("externalDroppedSamples"), I(s.external_dropped_samples)}};
    }
    m[EncodableValue("sinkCallbacks")] = I(sink.callbacks);
    m[EncodableValue("sinkNon16")] = I(sink.non16);
    m[EncodableValue("renderHresult")] = I(hresult);
    m[EncodableValue("mixRate")] = I(mix_rate);
    m[EncodableValue("mixChannels")] = I(mix_channels);
    m[EncodableValue("bufferFrames")] = I(buffer_frames);
    m[EncodableValue("renderCalls")] = I(render_calls);
    m[EncodableValue("renderWaitTimeouts")] = I(glitches);
    m[EncodableValue("attached")] = EncodableValue(static_cast<bool>(track));
    m[EncodableValue("referenceKind")] = EncodableValue("PCM handed to the application WASAPI render client (post-slot)");
    return m;
  }
};

PlayoutAudioPlugin::PlayoutAudioPlugin() : state_(std::make_unique<State>()) {}
PlayoutAudioPlugin::~PlayoutAudioPlugin() = default;

void PlayoutAudioPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(registrar->messenger(), "playout_audio",
                                                                         &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<PlayoutAudioPlugin>();
  channel->SetMethodCallHandler([p = plugin.get()](const auto& c, auto r) { p->Handle(c, std::move(r)); });
  registrar->AddPlugin(std::move(plugin));
}

void PlayoutAudioPlugin::Handle(const flutter::MethodCall<EncodableValue>& call,
                                std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  auto& s = *state_;
  const EncodableMap empty;
  auto args = call.arguments() ? std::get_if<EncodableMap>(call.arguments()) : nullptr;
  const auto& a = args ? *args : empty;
  const auto& name = call.method_name();
  if (name == "configure") {
    s.Dispose();
    s.pipeline = pipeline_create(Number(a, "delayMs", 20));
    auto id = Arg(a, "deviceId");
    s.endpoint = id && std::holds_alternative<std::string>(*id) ? std::get<std::string>(*id) : "";
    if (!s.pipeline) {
      result->Error("playout", "pipeline allocation failed");
      return;
    }
    result->Success(EncodableValue(s.Stats()));
    return;
  }
  if (name == "attachRemote") {
    auto id = Arg(a, "trackId");
    if (!s.pipeline || s.track || !id || !std::holds_alternative<std::string>(*id)) {
      result->Error("playout", "configure first / already attached / trackId");
      return;
    }
    auto* webrtc = FlutterWebRTCPluginSharedInstance();
    flutter_webrtc_plugin::FlutterWebRTCBase* base = webrtc;
    libwebrtc::scoped_refptr<libwebrtc::RTCMediaTrack> found;
    for (const auto& item : Access::Peers(base)) {
      for (const auto& receiver : item.second->receivers().std_vector()) {
        auto t = receiver->track();
        if (t && t->id().std_string() == std::get<std::string>(*id)) found = t;
      }
    }
    if (!found || found->kind().std_string() != "audio") {
      result->Error("playout", "no remote audio track");
      return;
    }
    s.track = libwebrtc::scoped_refptr<libwebrtc::RTCAudioTrack>(static_cast<libwebrtc::RTCAudioTrack*>(found.get()));
    s.track->SetVolume(0);  // native playout mixer gain only; the sink still gets decoded PCM
    {
      std::lock_guard<std::mutex> g(s.sink.lock);
      s.sink.pipeline = s.pipeline;
    }
    s.track->AddSink(&s.sink);
    const HRESULT hr = s.StartRender();
    if (FAILED(hr)) {
      s.Detach();
      result->Error("playout", "WASAPI render start failed", EncodableValue(static_cast<int64_t>(hr)));
      return;
    }
    result->Success(EncodableValue(s.Stats()));
    return;
  }
  if (name == "setMode") {
    if (s.pipeline) pipeline_set_mode(s.pipeline, Number(a, "mode", 0));
    result->Success(EncodableValue(s.Stats()));
    return;
  }
  if (name == "capture") {
    auto v = Arg(a, "bytes");
    if (!s.pipeline || !v || !std::holds_alternative<std::vector<uint8_t>>(*v)) {
      result->Error("playout", "configure and supply PCM16");
      return;
    }
    const auto& b = std::get<std::vector<uint8_t>>(*v);
    const int n = static_cast<int>(b.size() / 2), cap = n + 480;
    std::vector<int16_t> post(cap), pre(cap);
    const int written = pipeline_capture(s.pipeline, reinterpret_cast<const int16_t*>(b.data()), n, post.data(), pre.data(), cap);
    result->Success(EncodableValue(EncodableMap{{EncodableValue("post"), EncodableValue(Bytes(post.data(), written))},
                                                {EncodableValue("pre"), EncodableValue(Bytes(pre.data(), written))}}));
    return;
  }
  if (name == "pullExternal") {
    std::vector<int16_t> buf(48000);
    const int n = s.pipeline ? pipeline_external_pull(s.pipeline, buf.data(), 48000) : 0;
    result->Success(EncodableValue(Bytes(buf.data(), n)));
    return;
  }
  if (name == "pushExternal") {
    auto v = Arg(a, "bytes");
    if (s.pipeline && v && std::holds_alternative<std::vector<uint8_t>>(*v)) {
      const auto& b = std::get<std::vector<uint8_t>>(*v);
      pipeline_external_push(s.pipeline, reinterpret_cast<const int16_t*>(b.data()), static_cast<int>(b.size() / 2));
    }
    result->Success();
    return;
  }
  if (name == "stats") {
    result->Success(EncodableValue(s.Stats()));
    return;
  }
  if (name == "traces") {
    EncodableMap m;
    const char* names[] = {"received", "reference", "controlReference"};
    for (int w = 0; w < 3 && s.pipeline; ++w) {
      const int n = pipeline_trace(s.pipeline, w, nullptr, 0);
      std::vector<int16_t> t(n);
      pipeline_trace(s.pipeline, w, t.data(), n);
      m[EncodableValue(names[w])] = EncodableValue(Bytes(t.data(), t.size()));
    }
    if (s.pipeline) {
      const int pairs = pipeline_clock_map(s.pipeline, nullptr, 0);
      std::vector<int64_t> c(pairs * 2);
      pipeline_clock_map(s.pipeline, c.data(), pairs);
      std::vector<uint8_t> bytes(c.size() * 8);
      std::memcpy(bytes.data(), c.data(), bytes.size());
      m[EncodableValue("clockMap")] = EncodableValue(bytes);
    }
    result->Success(EncodableValue(m));
    return;
  }
  if (name == "detach") {
    s.Detach();
    result->Success(EncodableValue(s.Stats()));
    return;
  }
  if (name == "dispose") {
    auto stats = s.Stats();
    s.Dispose();
    result->Success(EncodableValue(stats));
    return;
  }
  result->NotImplemented();
}
}  // namespace playout_audio
