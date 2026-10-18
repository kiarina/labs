#include "windows_playout.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif

// clang-format off
#include <windows.h>
#include <audioclient.h>
#include <avrt.h>
#include <propkeydef.h>
#include <functiondiscoverykeys_devpkey.h>
#include <ks.h>
#include <ksmedia.h>
#include <mmdeviceapi.h>
#include <wrl/client.h>
// clang-format on

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <sstream>

namespace external_aec {
using Microsoft::WRL::ComPtr;
WindowsPlayout::~WindowsPlayout() { Stop(); }
bool WindowsPlayout::Start(Reference reference, Pull pull, double gain) {
  Stop();
  reference_ = std::move(reference);
  pull_ = std::move(pull);
  gain_ = std::clamp(gain, 0.0, 1.0);
  {
    std::lock_guard<std::mutex> lock(mutex_);
    stats_ = {};
  }
  event_ = CreateEventW(nullptr, FALSE, FALSE, nullptr);
  if (!event_) {
    SetError("CreateEvent", HRESULT_FROM_WIN32(GetLastError()));
    return false;
  }
  running_ = true;
  std::promise<bool> ready;
  auto future = ready.get_future();
  thread_ = std::thread(&WindowsPlayout::Run, this, std::move(ready));
  if (future.wait_for(std::chrono::seconds(5)) != std::future_status::ready) {
    SetError("WASAPI startup timeout", E_FAIL);
    Stop();
    return false;
  }
  const bool ok = future.get();
  if (!ok) Stop();
  return ok;
}
void WindowsPlayout::Stop() {
  running_ = false;
  if (event_) SetEvent(static_cast<HANDLE>(event_));
  if (thread_.joinable()) thread_.join();
  if (event_) {
    CloseHandle(static_cast<HANDLE>(event_));
    event_ = nullptr;
  }
  Flush();
}
void WindowsPlayout::Enqueue(const int16_t* pcm, size_t samples) {
  std::lock_guard<std::mutex> lock(mutex_);
  constexpr size_t maximum = 48000;
  for (size_t i = 0; i < samples; ++i) {
    if (queue_.size() >= maximum) {
      queue_.pop_front();
      ++stats_.discarded_samples;
    }
    queue_.push_back(pcm[i]);
  }
  stats_.queued_samples += samples;
}
void WindowsPlayout::Flush() {
  std::lock_guard<std::mutex> lock(mutex_);
  queue_.clear();
}
PlayoutStats WindowsPlayout::Stats() {
  std::lock_guard<std::mutex> lock(mutex_);
  return stats_;
}
void WindowsPlayout::SetError(const char* operation, long result) {
  std::ostringstream s;
  s << operation << ": 0x" << std::hex << static_cast<unsigned long>(result);
  std::lock_guard<std::mutex> lock(mutex_);
  stats_.error = s.str();
}
WindowsPlayout::Block WindowsPlayout::NextBlock() {
  Block block{};
  bool queued = false;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    queued = queue_.size() >= block.size();
    if (queued)
      for (auto& value : block) {
        value = queue_.front();
        queue_.pop_front();
      }
  }
  if (pull_) {
    Block decoded{};
    if (!pull_(decoded)) {
      std::lock_guard<std::mutex> lock(mutex_);
      ++stats_.pull_failures;
    }
    if (!queued) block = decoded;
  }
  for (auto& value : block) {
    value = static_cast<int16_t>(
        std::clamp(std::lround(value * gain_), -32768L, 32767L));
  }
  return block;
}
void WindowsPlayout::Run(std::promise<bool> started) {
  bool reported = false;
  const auto com = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(com))
    SetError("CoInitializeEx", com);
  else {
    [&] {
      ComPtr<IMMDeviceEnumerator> devices;
      auto hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                                 CLSCTX_ALL, IID_PPV_ARGS(&devices));
      if (FAILED(hr)) {
        SetError("DeviceEnumerator", hr);
        return;
      }
      ComPtr<IMMDevice> device;
      hr = devices->GetDefaultAudioEndpoint(eRender, eConsole, &device);
      if (FAILED(hr)) {
        SetError("Default render endpoint", hr);
        return;
      }
      ComPtr<IPropertyStore> props;
      if (SUCCEEDED(device->OpenPropertyStore(STGM_READ, &props))) {
        PROPVARIANT name;
        PropVariantInit(&name);
        if (SUCCEEDED(props->GetValue(PKEY_Device_FriendlyName, &name)) &&
            name.vt == VT_LPWSTR) {
          const int n = WideCharToMultiByte(CP_UTF8, 0, name.pwszVal, -1,
                                            nullptr, 0, nullptr, nullptr);
          std::string text(static_cast<size_t>(n), '\0');
          WideCharToMultiByte(CP_UTF8, 0, name.pwszVal, -1, text.data(), n,
                              nullptr, nullptr);
          if (!text.empty()) text.pop_back();
          std::lock_guard<std::mutex> lock(mutex_);
          stats_.device_name = text;
        }
        PropVariantClear(&name);
      }
      ComPtr<IAudioClient> client;
      hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                            reinterpret_cast<void**>(client.GetAddressOf()));
      if (FAILED(hr)) {
        SetError("Activate render client", hr);
        return;
      }
      WAVEFORMATEX* format = nullptr;
      hr = client->GetMixFormat(&format);
      if (FAILED(hr)) {
        SetError("GetMixFormat", hr);
        return;
      }
      const int channels = format->nChannels,
                rate = static_cast<int>(format->nSamplesPerSec),
                bits = format->wBitsPerSample;
      bool floating = format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT;
      bool integer = format->wFormatTag == WAVE_FORMAT_PCM;
      if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
          format->cbSize >= 22) {
        const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
        floating = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
        integer = IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
      }
      if (channels < 1 || channels > 16 || rate <= 0 || rate % 100 != 0 ||
          !((floating && bits == 32) ||
            (integer && (bits == 16 || bits == 24 || bits == 32)))) {
        SetError("Unsupported endpoint mix format",
                 AUDCLNT_E_UNSUPPORTED_FORMAT);
        CoTaskMemFree(format);
        return;
      }
      const int block_frames = rate / 100;
      hr = client->Initialize(AUDCLNT_SHAREMODE_SHARED,
                              AUDCLNT_STREAMFLAGS_EVENTCALLBACK, 200000, 0,
                              format, nullptr);
      CoTaskMemFree(format);
      if (FAILED(hr)) {
        SetError("Initialize exact mix format", hr);
        return;
      }
      hr = client->SetEventHandle(static_cast<HANDLE>(event_));
      if (FAILED(hr)) {
        SetError("SetEventHandle", hr);
        return;
      }
      UINT32 buffer_frames = 0;
      client->GetBufferSize(&buffer_frames);
      REFERENCE_TIME latency = 0;
      client->GetStreamLatency(&latency);
      if (buffer_frames < static_cast<UINT32>(block_frames)) {
        SetError("Render buffer smaller than 10 ms", E_FAIL);
        return;
      }
      {
        std::lock_guard<std::mutex> lock(mutex_);
        stats_.channels = channels;
        stats_.sample_rate = rate;
        stats_.bits = bits;
        stats_.floating_point = floating;
        stats_.buffer_frames = static_cast<int>(buffer_frames);
        stats_.latency_ms = static_cast<double>(latency) / 10000.0;
      }
      ComPtr<IAudioRenderClient> render;
      hr = client->GetService(IID_PPV_ARGS(&render));
      if (FAILED(hr)) {
        SetError("Get render service", hr);
        return;
      }
      ComPtr<IAudioClock> audio_clock;
      hr = client->GetService(IID_PPV_ARGS(&audio_clock));
      UINT64 clock_frequency = 0;
      if (FAILED(hr) || FAILED(audio_clock->GetFrequency(&clock_frequency)) ||
          !clock_frequency) {
        SetError("Get render clock", E_FAIL);
        return;
      }
      const auto clock_start = std::chrono::steady_clock::now();
      DWORD task_index = 0;
      auto mmcss = AvSetMmThreadCharacteristicsW(L"Audio", &task_index);
      hr = client->Start();
      if (FAILED(hr)) {
        SetError("Start render client", hr);
        if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
        return;
      }
      started.set_value(true);
      reported = true;
      while (running_) {
        WaitForSingleObject(static_cast<HANDLE>(event_), 50);
        if (!running_) break;
        UINT32 padding = 0;
        const auto padding_result = client->GetCurrentPadding(&padding);
        if (FAILED(padding_result)) {
          SetError("GetCurrentPadding", padding_result);
          break;
        }
        auto available = buffer_frames - padding;
        while (running_ && available >= static_cast<UINT32>(block_frames)) {
          BYTE* output = nullptr;
          hr = render->GetBuffer(static_cast<UINT32>(block_frames), &output);
          if (FAILED(hr)) {
            SetError("Get render buffer", hr);
            running_ = false;
            break;
          }
          const auto block = NextBlock();
          for (int frame = 0; frame < block_frames; ++frame) {
            const double position =
                static_cast<double>(frame) * 480 / block_frames;
            const auto left = static_cast<size_t>(position),
                       right = std::min(left + 1, block.size() - 1);
            const double sample =
                block[left] + (block[right] - block[left]) * (position - left);
            for (int ch = 0; ch < channels; ++ch) {
              const size_t index = static_cast<size_t>(frame) * channels + ch;
              if (floating)
                reinterpret_cast<float*>(output)[index] =
                    static_cast<float>(sample / 32768.0);
              else if (bits == 16)
                reinterpret_cast<int16_t*>(output)[index] =
                    static_cast<int16_t>(sample);
              else if (bits == 32)
                reinterpret_cast<int32_t*>(output)[index] =
                    static_cast<int32_t>(sample) * 65536;
              else {
                const auto value =
                    static_cast<uint32_t>(static_cast<int32_t>(sample) * 256);
                for (int b = 0; b < 3; ++b)
                  output[index * 3 + b] =
                      static_cast<BYTE>((value >> (b * 8)) & 255);
              }
            }
          }
          hr = render->ReleaseBuffer(static_cast<UINT32>(block_frames), 0);
          if (FAILED(hr)) {
            SetError("Release render buffer", hr);
            running_ = false;
            break;
          }
          // Feed the reference only after a successful DAC-buffer submission.
          if (reference_) reference_(block);
          {
            std::lock_guard<std::mutex> lock(mutex_);
            ++stats_.rendered_blocks;
            const auto elapsed_us = static_cast<uint64_t>(
                std::chrono::duration_cast<std::chrono::microseconds>(
                    std::chrono::steady_clock::now() - clock_start)
                    .count());
            if (!stats_.first_render_us) stats_.first_render_us = elapsed_us;
            stats_.last_render_us = elapsed_us;
            stats_.clock_frequency = clock_frequency;
            UINT64 position = 0, qpc = 0;
            if (SUCCEEDED(audio_clock->GetPosition(&position, &qpc)))
              stats_.played_frames = static_cast<uint64_t>(
                  static_cast<long double>(position) * 48000 / clock_frequency);

            if (std::all_of(block.begin(), block.end(),
                            [](int16_t x) { return x == 0; }))
              ++stats_.silence_blocks;
            stats_.latency_ms =
                static_cast<double>(latency) / 10000.0 +
                1000.0 * (buffer_frames - available + block_frames) / rate;
          }
          available -= static_cast<UINT32>(block_frames);
        }
      }
      client->Stop();
      if (mmcss) AvRevertMmThreadCharacteristics(mmcss);
    }();
    CoUninitialize();
  }
  if (!reported) started.set_value(false);
  running_ = false;
}
}  // namespace external_aec
