#include "playout_pipeline.h"
#include <algorithm>
#include <deque>
#include <mutex>
#include <vector>
#include "aec_engine.h"
#include "playout_slot.h"

namespace {
constexpr size_t kBlock = 480;
constexpr size_t kPrime = 1920;               // 40 ms before the speaker starts
constexpr size_t kMaxQueue = 48000;           // 1 s bound, oldest dropped
constexpr size_t kMaxTrace = 48000 * 300;     // 5 min per trace

struct Pipeline {
  // Real-time threads (sink, speaker) only take short copy locks; AEC runs
  // under dsp_mutex on the capture thread and never blocks them.
  std::mutex input_mutex, queue_mutex, ref_mutex, dsp_mutex, stats_mutex;
  void* slot = slot_create();
  void* post = aec_create_config(1, 0);
  void* pre = aec_create_config(1, 0);
  int delay_ms;
  // Input side (sink thread).
  double resample_position = 0;
  int16_t last_sample = 0;
  std::vector<int16_t> pending;
  // Speaker FIFO with the pre-slot samples in lockstep.
  std::deque<int16_t> played, played_pre;
  bool primed = false;
  // References waiting for the capture thread.
  std::vector<int16_t> reference, reference_pre;
  std::vector<int16_t> capture_pending;
  std::vector<int16_t> trace[3];
  std::deque<int16_t> external_out, external_pre;  // to the processor / pre-slot awaiting pairing
  std::vector<int64_t> clock_map;
  int64_t captured = 0;
  pipeline_stats stats{};
  explicit Pipeline(int delay) : delay_ms(delay) {}
  ~Pipeline() {
    slot_destroy(slot);
    aec_destroy(post);
    aec_destroy(pre);
  }
  void Trace(int which, const int16_t* p, size_t n) {
    auto& t = trace[which];
    const size_t room = kMaxTrace > t.size() ? kMaxTrace - t.size() : 0;
    const size_t take = std::min(room, n);
    t.insert(t.end(), p, p + take);
    stats.trace_dropped_samples += static_cast<int64_t>(n - take);
  }
};
}  // namespace

extern "C" {
void* pipeline_create(int delay_ms) {
  try {
    auto* p = new Pipeline(delay_ms);
    if (!p->slot || !p->post || !p->pre) {
      delete p;
      return nullptr;
    }
    return p;
  } catch (...) {
    return nullptr;
  }
}

void pipeline_set_mode(void* handle, int mode) {
  auto& p = *static_cast<Pipeline*>(handle);
  std::lock_guard<std::mutex> lock(p.input_mutex);
  slot_set_mode(p.slot, mode);
  std::lock_guard<std::mutex> queue(p.queue_mutex);
  p.external_out.clear();
  p.external_pre.clear();
  p.stats.external_pending_samples = 0;
}

void pipeline_received(void* handle, const int16_t* pcm, int frames, int channels, int rate) {
  if (!handle || !pcm || frames <= 0 || channels <= 0 || rate <= 0) return;
  auto& p = *static_cast<Pipeline*>(handle);
  std::lock_guard<std::mutex> lock(p.input_mutex);
  p.stats.received_frames += frames;
  p.stats.received_rate = rate;
  p.stats.received_channels = channels;
  const double step = static_cast<double>(rate) / 48000.0;
  for (int f = 0; f < frames; ++f) {
    int sum = 0;
    for (int c = 0; c < channels; ++c) sum += pcm[f * channels + c];
    const int16_t current = static_cast<int16_t>(sum / channels);
    if (rate == 48000) {
      p.pending.push_back(current);
    } else {
      // Emit output samples whose positions fall in (f-1, f].
      while (p.resample_position <= 1.0) {
        const double t = p.resample_position;
        p.pending.push_back(static_cast<int16_t>(p.last_sample + (current - p.last_sample) * t));
        p.resample_position += step;
      }
      p.resample_position -= 1.0;
    }
    p.last_sample = current;
  }
  std::vector<int16_t> blocks_in, blocks_out;
  while (p.pending.size() >= kBlock) {
    int16_t out[kBlock];
    slot_process(p.slot, p.pending.data(), out, kBlock);
    blocks_in.insert(blocks_in.end(), p.pending.begin(), p.pending.begin() + kBlock);
    blocks_out.insert(blocks_out.end(), out, out + kBlock);
    p.pending.erase(p.pending.begin(), p.pending.begin() + kBlock);
    ++p.stats.slot_blocks;
  }
  p.stats.slot_mode = slot_mode(p.slot);
  p.stats.slot_latency_samples = slot_latency_samples(p.slot);
  if (blocks_out.empty()) return;
  std::lock_guard<std::mutex> queue(p.queue_mutex);
  p.Trace(0, blocks_in.data(), blocks_in.size());
  if (slot_mode(p.slot) == SLOT_EXTERNAL) {
    p.external_out.insert(p.external_out.end(), blocks_in.begin(), blocks_in.end());
    p.external_pre.insert(p.external_pre.end(), blocks_in.begin(), blocks_in.end());
    while (p.external_pre.size() > 48000 * 3) {  // processor stalled: keep the latest 3 s
      p.external_pre.pop_front();
      ++p.stats.external_dropped_samples;
    }
    while (p.external_out.size() > 48000 * 3) p.external_out.pop_front();
    p.stats.external_pending_samples = static_cast<int64_t>(p.external_pre.size());
    p.stats.external_max_pending_samples = std::max(p.stats.external_max_pending_samples, p.stats.external_pending_samples);
    return;
  }
  p.played.insert(p.played.end(), blocks_out.begin(), blocks_out.end());
  p.played_pre.insert(p.played_pre.end(), blocks_in.begin(), blocks_in.end());
  while (p.played.size() > kMaxQueue) {
    p.played.pop_front();
    p.played_pre.pop_front();
    ++p.stats.overflow_samples;
  }
}

void pipeline_render(void* handle, int16_t* out, int frames) {
  auto& p = *static_cast<Pipeline*>(handle);
  int16_t pre[4096];
  for (int done = 0; done < frames;) {
    const int n = std::min(frames - done, 4096);
    int16_t* o = out + done;
    {
      std::lock_guard<std::mutex> lock(p.queue_mutex);
      if (!p.primed && p.played.size() >= kPrime) p.primed = true;
      for (int i = 0; i < n; ++i) {
        if (p.primed && !p.played.empty()) {
          o[i] = p.played.front();
          pre[i] = p.played_pre.front();
          p.played.pop_front();
          p.played_pre.pop_front();
        } else {
          o[i] = 0;
          pre[i] = 0;
          if (p.primed) {
            ++p.stats.underflow_samples;
            p.primed = false;  // re-prime after a gap
          }
        }
      }
      p.stats.played_samples += n;
      p.stats.queued_samples = static_cast<int64_t>(p.played.size());
      p.stats.primed = p.primed;
      p.Trace(1, o, n);
      p.Trace(2, pre, n);
    }
    {
      std::lock_guard<std::mutex> lock(p.ref_mutex);
      p.reference.insert(p.reference.end(), o, o + n);
      p.reference_pre.insert(p.reference_pre.end(), pre, pre + n);
      // Never let an idle capture side grow references without bound.
      const size_t cap = 48000 * 2;
      if (p.reference.size() > cap) {
        const size_t drop = p.reference.size() - cap;
        p.reference.erase(p.reference.begin(), p.reference.begin() + drop);
        p.reference_pre.erase(p.reference_pre.begin(), p.reference_pre.begin() + drop);
      }
    }
    done += n;
  }
}

int pipeline_capture(void* handle, const int16_t* in, int n, int16_t* post, int16_t* pre, int capacity) {
  auto& p = *static_cast<Pipeline*>(handle);
  std::lock_guard<std::mutex> lock(p.dsp_mutex);
  std::vector<int16_t> ref, ref_pre;
  {
    std::lock_guard<std::mutex> copy(p.ref_mutex);
    const size_t take = p.reference.size() / kBlock * kBlock;
    ref.assign(p.reference.begin(), p.reference.begin() + take);
    ref_pre.assign(p.reference_pre.begin(), p.reference_pre.begin() + take);
    p.reference.erase(p.reference.begin(), p.reference.begin() + take);
    p.reference_pre.erase(p.reference_pre.begin(), p.reference_pre.begin() + take);
  }
  for (size_t r = 0; r < ref.size(); r += kBlock) {
    if (aec_reverse(p.post, ref.data() + r, kBlock)) ++p.stats.dsp_errors;
    if (aec_reverse(p.pre, ref_pre.data() + r, kBlock)) ++p.stats.dsp_errors;
    ++p.stats.reference_blocks;
    ++p.stats.control_reference_blocks;
  }
  p.capture_pending.insert(p.capture_pending.end(), in, in + n);
  p.captured += n;
  if (p.clock_map.size() < 2 * 48000) {
    int64_t played;
    {
      std::lock_guard<std::mutex> q(p.queue_mutex);
      played = p.stats.played_samples;
    }
    p.clock_map.push_back(p.captured);
    p.clock_map.push_back(played);
  }
  int written = 0;
  size_t offset = 0;
  while (p.capture_pending.size() - offset >= kBlock && written + static_cast<int>(kBlock) <= capacity) {
    if (aec_capture(p.post, p.capture_pending.data() + offset, post + written, kBlock, p.delay_ms)) ++p.stats.dsp_errors;
    if (aec_capture(p.pre, p.capture_pending.data() + offset, pre + written, kBlock, p.delay_ms)) ++p.stats.dsp_errors;
    offset += kBlock;
    written += kBlock;
    p.stats.capture_samples += kBlock;
  }
  p.capture_pending.erase(p.capture_pending.begin(), p.capture_pending.begin() + offset);
  return written;
}

int pipeline_external_pull(void* handle, int16_t* out, int capacity) {
  auto& p = *static_cast<Pipeline*>(handle);
  std::lock_guard<std::mutex> lock(p.queue_mutex);
  const int n = std::min(capacity, static_cast<int>(p.external_out.size()));
  for (int i = 0; i < n; ++i) {
    out[i] = p.external_out.front();
    p.external_out.pop_front();
  }
  p.stats.external_pulled_samples += n;
  return n;
}

void pipeline_external_push(void* handle, const int16_t* pcm, int n) {
  auto& p = *static_cast<Pipeline*>(handle);
  std::lock_guard<std::mutex> lock(p.queue_mutex);
  for (int i = 0; i < n; ++i) {
    p.played.push_back(pcm[i]);
    int16_t pre = 0;
    if (!p.external_pre.empty()) {
      pre = p.external_pre.front();
      p.external_pre.pop_front();
    }
    p.played_pre.push_back(pre);
  }
  while (p.played.size() > kMaxQueue) {
    p.played.pop_front();
    p.played_pre.pop_front();
    ++p.stats.overflow_samples;
  }
  p.stats.external_returned_samples += n;
  p.stats.external_pending_samples = static_cast<int64_t>(p.external_pre.size());
}

void pipeline_stats_get(void* handle, pipeline_stats* stats) {
  auto& p = *static_cast<Pipeline*>(handle);
  std::scoped_lock lock(p.input_mutex, p.queue_mutex, p.dsp_mutex);
  *stats = p.stats;
}

int pipeline_trace(void* handle, int which, int16_t* out, int capacity) {
  if (which < 0 || which > 2) return -1;
  auto& p = *static_cast<Pipeline*>(handle);
  std::lock_guard<std::mutex> lock(p.queue_mutex);
  const auto& t = p.trace[which];
  const int n = static_cast<int>(t.size());
  if (out) std::copy(t.begin(), t.begin() + std::min(n, capacity), out);
  return n;
}

int pipeline_clock_map(void* handle, int64_t* out, int capacity_pairs) {
  auto& p = *static_cast<Pipeline*>(handle);
  std::lock_guard<std::mutex> lock(p.dsp_mutex);
  const int pairs = static_cast<int>(p.clock_map.size() / 2);
  if (out) std::copy(p.clock_map.begin(), p.clock_map.begin() + 2 * std::min(pairs, capacity_pairs), out);
  return pairs;
}

void pipeline_destroy(void* handle) { delete static_cast<Pipeline*>(handle); }
}
