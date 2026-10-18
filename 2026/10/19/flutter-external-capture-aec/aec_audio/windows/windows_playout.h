#pragma once

#include <array>
#include <atomic>
#include <cstdint>
#include <deque>
#include <functional>
#include <future>
#include <mutex>
#include <string>
#include <thread>

namespace external_aec {
struct PlayoutStats {
  uint64_t rendered_blocks = 0, queued_samples = 0, silence_blocks = 0;
  uint64_t discarded_samples = 0, pull_failures = 0;
  uint64_t played_frames = 0, clock_frequency = 0, first_render_us = 0,
           last_render_us = 0;
  int sample_rate = 0, channels = 0, bits = 0, buffer_frames = 0;
  bool floating_point = false;
  double latency_ms = 0;
  std::string device_name, error;
};

// A dedicated WASAPI render clock. It never creates a capture client.
class WindowsPlayout {
 public:
  using Block = std::array<int16_t, 480>;
  using Pull = std::function<bool(Block&)>;
  using Reference = std::function<void(const Block&)>;
  ~WindowsPlayout();
  bool Start(Reference reference, Pull pull = {}, double gain = 1.0);
  void Stop();
  void Enqueue(const int16_t* pcm, size_t samples);
  void Flush();
  PlayoutStats Stats();

 private:
  void Run(std::promise<bool> started);
  void SetError(const char* operation, long result);
  Block NextBlock();
  std::atomic<bool> running_{false};
  void* event_ = nullptr;
  std::thread thread_;
  std::mutex mutex_;
  std::deque<int16_t> queue_;
  PlayoutStats stats_;
  Reference reference_;
  Pull pull_;
  double gain_ = 1.0;
};
}  // namespace external_aec
