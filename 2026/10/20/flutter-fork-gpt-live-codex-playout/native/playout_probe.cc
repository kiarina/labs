// Device-free check of the slot/pipeline/AEC wiring.
// Far speech is "received", processed by the slot and "played"; the simulated
// microphone hears the played signal 80 ms later at gain 0.5. The post AEC uses
// the played reference, the control AEC the pre-slot reference. Prints JSON.
#include <cmath>
#include <cstdio>
#include <vector>
#include "playout_pipeline.h"
#include "playout_slot.h"

static double Db(const std::vector<int16_t>& v, size_t s, size_t e) {
  double sum = 0;
  for (size_t i = s; i < e; ++i) sum += double(v[i]) * v[i];
  return 10 * std::log10(sum / std::max<size_t>(1, e - s) / (32768.0 * 32768.0) + 1e-24);
}

int main(int argc, char** argv) {
  if (argc < 2) return 2;
  FILE* f = std::fopen(argv[1], "rb");
  if (!f) return 2;
  std::vector<int16_t> far;
  int16_t s;
  while (std::fread(&s, 2, 1, f) == 1) far.push_back(s);
  std::fclose(f);
  const char* names[] = {"passthrough", "delay200ms", "pitchUp"};
  std::printf("{\"echoDelayMs\":80,\"echoGain\":0.5,\"modes\":{");
  for (int mode = 0; mode < 3; ++mode) {
    void* p = pipeline_create(20);
    pipeline_set_mode(p, mode);
    const size_t total = 48000 * 20;  // 20 s, last 5 s evaluated
    std::vector<int16_t> played(total), mic(total), post(total), pre(total);
    std::vector<int16_t> history(3840, 0);  // 80 ms echo path
    size_t write = 0, hp = 0;
    std::vector<int16_t> post_block(4800), pre_block(4800);
    for (size_t t = 0; t < total; t += 480) {
      std::vector<int16_t> in(480);
      for (int i = 0; i < 480; ++i) in[i] = far[(t + i) % far.size()];
      pipeline_received(p, in.data(), 480, 1, 48000);
      int16_t out[480];
      pipeline_render(p, out, 480);
      std::vector<int16_t> capture(480);
      for (int i = 0; i < 480; ++i) {
        played[t + i] = out[i];
        capture[i] = static_cast<int16_t>(history[hp] * .5);
        history[hp] = out[i];
        hp = (hp + 1) % history.size();
        mic[t + i] = capture[i];
      }
      const int n = pipeline_capture(p, capture.data(), 480, post_block.data(), pre_block.data(), 4800);
      for (int i = 0; i < n && write < total; ++i, ++write) {
        post[write] = post_block[i];
        pre[write] = pre_block[i];
      }
    }
    pipeline_stats st;
    pipeline_stats_get(p, &st);
    const size_t a = 48000 * 15, b = 48000 * 20 - 4800;
    const double micDb = Db(mic, a, b), postDb = Db(post, a, b), preDb = Db(pre, a, b);
    std::printf("%s\"%s\":{\"micDbfs\":%.2f,\"postReferenceDbfs\":%.2f,\"preReferenceDbfs\":%.2f,"
                "\"postReductionDb\":%.2f,\"preReductionDb\":%.2f,\"underflowSamples\":%lld,"
                "\"slotLatencySamples\":%lld,\"dspErrors\":%lld}",
                mode ? "," : "", names[mode], micDb, postDb, preDb, micDb - postDb, micDb - preDb,
                (long long)st.underflow_samples, (long long)st.slot_latency_samples, (long long)st.dsp_errors);
    pipeline_destroy(p);
  }
  std::printf("}}\n");
  return 0;
}
