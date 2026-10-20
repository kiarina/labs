#include "tts_pcm_plugin.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Media.SpeechSynthesis.h>
#include <winrt/Windows.Storage.Streams.h>

#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace tts_pcm {

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;
using winrt::Windows::Media::SpeechSynthesis::SpeechSynthesizer;
using winrt::Windows::Media::SpeechSynthesis::VoiceInformation;

constexpr UINT kResultMessage = WM_APP + 0x3a7;

// What a worker thread hands back to the platform thread.
struct Outcome {
  std::string id;
  std::vector<uint8_t> pcm;  // 16-bit little-endian mono
  int sample_rate = 0;
  std::string format;
  std::string error;
};

std::string Utf8(const winrt::hstring& s) { return winrt::to_string(s); }

const std::string* GetString(const EncodableMap& m, const char* key) {
  auto it = m.find(EncodableValue(key));
  if (it == m.end()) return nullptr;
  return std::get_if<std::string>(&it->second);
}

uint32_t U32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (uint32_t(p[3]) << 24); }
uint16_t U16(const uint8_t* p) { return uint16_t(p[0] | (p[1] << 8)); }

// Pulls the first channel out of a RIFF/WAVE buffer as 16-bit PCM.
bool WavToInt16Mono(const std::vector<uint8_t>& wav, Outcome& out) {
  if (wav.size() < 12 || std::memcmp(wav.data(), "RIFF", 4) != 0) return false;
  uint16_t tag = 0, channels = 0, bits = 0;
  uint32_t rate = 0;
  size_t pos = 12;
  while (pos + 8 <= wav.size()) {
    const uint8_t* h = wav.data() + pos;
    uint32_t size = U32(h + 4);
    const uint8_t* body = h + 8;
    if (std::memcmp(h, "fmt ", 4) == 0 && pos + 8 + 16 <= wav.size()) {
      tag = U16(body);
      channels = U16(body + 2);
      rate = U32(body + 4);
      bits = U16(body + 14);
    } else if (std::memcmp(h, "data", 4) == 0) {
      size_t n = std::min<size_t>(size, wav.size() - pos - 8);
      if (channels == 0 || bits == 0) return false;
      size_t frame = size_t(channels) * bits / 8;
      size_t frames = n / frame;
      out.pcm.resize(frames * 2);
      for (size_t i = 0; i < frames; i++) {
        const uint8_t* s = body + i * frame;
        int16_t v = 0;
        if (tag == 1 && bits == 16) {
          v = int16_t(U16(s));
        } else if (tag == 3 && bits == 32) {
          float f;
          std::memcpy(&f, s, 4);
          f = f > 1 ? 1 : (f < -1 ? -1 : f);
          v = int16_t(f * 32767);
        } else if (tag == 1 && bits == 8) {
          v = int16_t((int(s[0]) - 128) << 8);
        } else {
          return false;
        }
        out.pcm[i * 2] = uint8_t(v & 0xff);
        out.pcm[i * 2 + 1] = uint8_t((v >> 8) & 0xff);
      }
      out.sample_rate = int(rate);
      out.format = std::string(tag == 3 ? "float" : "pcm") + std::to_string(bits) + " " +
                   std::to_string(rate) + " Hz " + std::to_string(channels) + " ch";
      return true;
    }
    pos += 8 + size + (size & 1);
  }
  return false;
}

void Synthesize(Outcome& out, const std::wstring& text, const std::string& voice,
                const std::string& language, double rate) {
  SpeechSynthesizer synth;
  auto voices = SpeechSynthesizer::AllVoices();
  bool chosen = false;
  if (!voice.empty()) {
    for (auto const& v : voices) {
      if (Utf8(v.Id()) == voice) {
        synth.Voice(v);
        chosen = true;
        break;
      }
    }
  }
  if (!chosen && !language.empty()) {
    auto lower = [](std::string s) {
      for (auto& c : s) c = char(tolower(c));
      return s;
    };
    std::string want = lower(language);
    for (auto const& v : voices) {
      if (lower(Utf8(v.Language())).rfind(want, 0) == 0) {
        synth.Voice(v);
        break;
      }
    }
  }
  synth.Options().SpeakingRate(rate);
  auto stream = synth.SynthesizeTextToStreamAsync(winrt::hstring(text)).get();
  auto size = uint32_t(stream.Size());
  winrt::Windows::Storage::Streams::DataReader reader(stream.GetInputStreamAt(0));
  reader.LoadAsync(size).get();
  std::vector<uint8_t> wav(size);
  reader.ReadBytes(wav);
  if (!WavToInt16Mono(wav, out)) out.error = "unsupported WAV from SpeechSynthesizer";
}

}  // namespace

void TtsPcmPlugin::RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
  auto channel = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      registrar->messenger(), "tts_pcm", &flutter::StandardMethodCodec::GetInstance());
  auto plugin = std::make_unique<TtsPcmPlugin>(registrar, std::move(channel));
  registrar->AddPlugin(std::move(plugin));
}

TtsPcmPlugin::TtsPcmPlugin(flutter::PluginRegistrarWindows* registrar,
                           std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel)
    : registrar_(registrar), channel_(std::move(channel)) {
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    HandleMethodCall(call, std::move(result));
  });
  window_proc_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
        return HandleWindowProc(hwnd, message, wparam, lparam);
      });
}

TtsPcmPlugin::~TtsPcmPlugin() {
  registrar_->UnregisterTopLevelWindowProcDelegate(window_proc_id_);
}

void TtsPcmPlugin::HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const auto* args = std::get_if<EncodableMap>(call.arguments());
  const std::string& method = call.method_name();
  if (method == "voices") {
    EncodableList list;
    try {
      for (auto const& v : SpeechSynthesizer::AllVoices()) {
        list.push_back(EncodableValue(EncodableMap{
            {EncodableValue("id"), EncodableValue(Utf8(v.Id()))},
            {EncodableValue("name"), EncodableValue(Utf8(v.DisplayName()))},
            {EncodableValue("language"), EncodableValue(Utf8(v.Language()))},
            {EncodableValue("quality"), EncodableValue(std::string("onecore"))},
        }));
      }
    } catch (const winrt::hresult_error& e) {
      result->Error("unavailable", Utf8(e.message()));
      return;
    }
    result->Success(EncodableValue(list));
  } else if (method == "synthesize" && args) {
    const std::string* id = GetString(*args, "id");
    const std::string* text = GetString(*args, "text");
    if (!id || !text) {
      result->Error("invalid", "id and text are required");
      return;
    }
    const std::string* voice = GetString(*args, "voice");
    const std::string* language = GetString(*args, "language");
    double rate = 1.0;
    auto r = args->find(EncodableValue("rate"));
    if (r != args->end()) {
      if (auto d = std::get_if<double>(&r->second)) rate = *d;
    }
    {
      std::lock_guard<std::mutex> lock(mutex_);
      running_.insert(*id);
    }
    HWND hwnd = GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
    std::wstring wtext(winrt::to_hstring(*text));
    std::string v = voice ? *voice : "";
    std::string l = language ? *language : "";
    std::string request_id = *id;
    std::thread([hwnd, request_id, wtext, v, l, rate]() {
      winrt::init_apartment(winrt::apartment_type::multi_threaded);
      auto out = new Outcome();
      out->id = request_id;
      try {
        Synthesize(*out, wtext, v, l, rate);
      } catch (const winrt::hresult_error& e) {
        out->error = Utf8(e.message());
      } catch (const std::exception& e) {
        out->error = e.what();
      }
      if (!PostMessage(hwnd, kResultMessage, 0, reinterpret_cast<LPARAM>(out))) delete out;
      winrt::uninit_apartment();
    }).detach();
    result->Success();
  } else if (method == "cancel" && args) {
    if (const std::string* id = GetString(*args, "id")) {
      std::lock_guard<std::mutex> lock(mutex_);
      running_.erase(*id);
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}

std::optional<LRESULT> TtsPcmPlugin::HandleWindowProc(HWND, UINT message, WPARAM, LPARAM lparam) {
  if (message != kResultMessage) return std::nullopt;
  std::unique_ptr<Outcome> out(reinterpret_cast<Outcome*>(lparam));
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (running_.erase(out->id) == 0) return 0;  // cancelled
  }
  if (!out->error.empty()) {
    channel_->InvokeMethod("error", std::make_unique<EncodableValue>(EncodableMap{
                                        {EncodableValue("id"), EncodableValue(out->id)},
                                        {EncodableValue("message"), EncodableValue(out->error)},
                                    }));
    return 0;
  }
  channel_->InvokeMethod("chunk", std::make_unique<EncodableValue>(EncodableMap{
                                      {EncodableValue("id"), EncodableValue(out->id)},
                                      {EncodableValue("pcm"), EncodableValue(out->pcm)},
                                      {EncodableValue("sampleRate"), EncodableValue(out->sample_rate)},
                                      {EncodableValue("format"), EncodableValue(out->format)},
                                  }));
  channel_->InvokeMethod("done", std::make_unique<EncodableValue>(EncodableMap{
                                     {EncodableValue("id"), EncodableValue(out->id)},
                                 }));
  return 0;
}

}  // namespace tts_pcm
