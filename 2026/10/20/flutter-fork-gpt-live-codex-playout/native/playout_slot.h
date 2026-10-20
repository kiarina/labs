#pragma once
#include <stdint.h>
#include "aec_engine.h"

// Processing slot between the decoded remote voice and the application-owned
// speaker. Synchronous 480-sample (10 ms, 48 kHz mono PCM16) blocks.
// Mode 0 passes audio through. Modes 1 and 2 are stand-ins that change what
// is played, so a reference taken before the slot would no longer match the
// speaker: 1 delays by 200 ms, 2 shifts pitch up by ratio 1.12.
// A future voice-conversion stage replaces the mode implementation behind the
// same block contract and reports its latency through slot_latency_samples.
#ifdef __cplusplus
extern "C" {
#endif
enum { SLOT_PASSTHROUGH = 0, SLOT_DELAY_200MS = 1, SLOT_PITCH_UP = 2 };
AEC_EXPORT void* slot_create(void);
AEC_EXPORT int slot_set_mode(void* handle, int mode);
AEC_EXPORT int slot_mode(void* handle);
AEC_EXPORT int slot_process(void* handle, const int16_t* in, int16_t* out, int samples);
AEC_EXPORT int slot_latency_samples(void* handle);
AEC_EXPORT void slot_destroy(void* handle);
#ifdef __cplusplus
}
#endif
