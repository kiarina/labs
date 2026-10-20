#include "playout_slot.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace {
constexpr int kDelay = 9600;     // 200 ms at 48 kHz
constexpr int kGrain = 1920;     // 40 ms pitch-shifter window
constexpr double kRatio = 1.12;  // about +2 semitones
constexpr double kPi = 3.14159265358979323846;

struct Slot {
  int mode = SLOT_PASSTHROUGH;
  std::vector<float> line = std::vector<float>(16384, 0.f);  // power of two
  int write = 0;
  double phase = 0;
  void Reset() {
    std::fill(line.begin(), line.end(), 0.f);
    write = 0;
    phase = 0;
  }
  float Read(double delay) const {
    const int mask = static_cast<int>(line.size()) - 1;
    const double position = write - delay;
    const int base = static_cast<int>(std::floor(position));
    const double frac = position - base;
    const float a = line[base & mask], b = line[(base + 1) & mask];
    return static_cast<float>(a + (b - a) * frac);
  }
  float Step(float x) {
    const int mask = static_cast<int>(line.size()) - 1;
    line[write & mask] = x;
    float y = x;
    if (mode == SLOT_DELAY_200MS) {
      y = line[(write - kDelay) & mask];
    } else if (mode == SLOT_PITCH_UP) {
      // Two read taps sweep a delay line; crossfaded with sin^2 windows.
      float sum = 0;
      for (int tap = 0; tap < 2; ++tap) {
        double p = phase + tap * .5;
        p -= std::floor(p);
        const double weight = std::sin(kPi * p) * std::sin(kPi * p);
        sum += static_cast<float>(weight) * Read(1 + kGrain * (1 - p));
      }
      y = sum;
      phase += (kRatio - 1) / kGrain;
      phase -= std::floor(phase);
    }
    ++write;
    return y;
  }
};
}  // namespace

extern "C" {
void* slot_create(void) {
  try {
    return new Slot();
  } catch (...) {
    return nullptr;
  }
}
int slot_set_mode(void* handle, int mode) {
  if (!handle || mode < SLOT_PASSTHROUGH || mode > SLOT_EXTERNAL) return -1;
  auto& slot = *static_cast<Slot*>(handle);
  if (slot.mode != mode) {
    slot.mode = mode;
    slot.Reset();
  }
  return 0;
}
int slot_mode(void* handle) { return handle ? static_cast<Slot*>(handle)->mode : -1; }
int slot_process(void* handle, const int16_t* in, int16_t* out, int samples) {
  if (!handle || !in || !out || samples <= 0) return -1;
  auto& slot = *static_cast<Slot*>(handle);
  for (int i = 0; i < samples; ++i) {
    const float y = slot.Step(static_cast<float>(in[i]));
    out[i] = static_cast<int16_t>(std::clamp(std::lrint(y), -32768L, 32767L));
  }
  return 0;
}
int slot_latency_samples(void* handle) {
  if (!handle) return -1;
  const int mode = static_cast<Slot*>(handle)->mode;
  return mode == SLOT_DELAY_200MS ? kDelay : mode == SLOT_PITCH_UP ? kGrain / 2 : 0;
}
void slot_destroy(void* handle) { delete static_cast<Slot*>(handle); }
}
