#pragma once
#include <stddef.h>
#include <stdint.h>
#include "aec_engine.h"

// Decoded remote PCM -> processing slot -> application speaker FIFO.
// The PCM actually handed to the speaker is the AEC render reference.
// A second, control AEC instead receives the pre-slot PCM in lockstep, to show
// what happens when the reference is taken before the slot.
// Device-free: the platform plugin owns the remote-track sink and the speaker.
#ifdef __cplusplus
extern "C" {
#endif
typedef struct pipeline_stats {
  int64_t received_frames, received_rate, received_channels;
  int64_t slot_blocks, played_samples, underflow_samples, overflow_samples;
  int64_t reference_blocks, control_reference_blocks, capture_samples;
  int64_t dsp_errors, trace_dropped_samples, queued_samples, slot_mode;
  int64_t slot_latency_samples, primed;
  // External processor (slot mode 3): received but not yet returned, returned
  // samples, pulls, and the largest pending backlog seen.
  int64_t external_pending_samples, external_returned_samples, external_pulled_samples, external_max_pending_samples;
  int64_t external_dropped_samples;
} pipeline_stats;

AEC_EXPORT void* pipeline_create(int delay_ms);
AEC_EXPORT void pipeline_set_mode(void* handle, int mode);
// Any rate/channel count; down-mixed and linearly resampled to 48 kHz mono.
AEC_EXPORT void pipeline_received(void* handle, const int16_t* pcm, int frames, int channels, int rate);
// Speaker callback: always fills `frames` mono samples (zeros on underflow).
AEC_EXPORT void pipeline_render(void* handle, int16_t* out, int frames);
// Capture: n samples of 48 kHz mono. Writes processed blocks to post/pre and
// returns the number of samples written (multiples of 480; remainder kept).
AEC_EXPORT int pipeline_capture(void* handle, const int16_t* in, int n, int16_t* post, int16_t* pre, int capacity);
// External processor (slot mode 3). pull: received 48 kHz mono samples not yet
// handed out (copies up to capacity, returns count). push: processed 48 kHz mono
// samples to play; the same number of pre-slot samples is paired for the control
// reference.
AEC_EXPORT int pipeline_external_pull(void* handle, int16_t* out, int capacity);
AEC_EXPORT void pipeline_external_push(void* handle, const int16_t* pcm, int n);
AEC_EXPORT void pipeline_stats_get(void* handle, pipeline_stats* stats);
// Traces of the bounded session: 0 pre-slot received, 1 played reference,
// 2 lockstep pre-slot reference. Returns sample count; copies when out != NULL.
AEC_EXPORT int pipeline_trace(void* handle, int which, int16_t* out, int capacity);
// Clock map: one (capture samples received incl. this call, speaker samples
// rendered) pair per capture call. Returns pair count; copies when out != NULL.
AEC_EXPORT int pipeline_clock_map(void* handle, int64_t* out, int capacity_pairs);
AEC_EXPORT void pipeline_destroy(void* handle);
#ifdef __cplusplus
}
#endif
