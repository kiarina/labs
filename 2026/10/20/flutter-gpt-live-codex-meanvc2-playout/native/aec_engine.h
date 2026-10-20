#pragma once
#include <stdint.h>
#if defined(_WIN32)
#if defined(AEC_ENGINE_BUILD)
#define AEC_EXPORT __declspec(dllexport)
#else
#define AEC_EXPORT __declspec(dllimport)
#endif
#else
#define AEC_EXPORT __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif
AEC_EXPORT void* aec_create(int enabled);
AEC_EXPORT void* aec_create_config(int enabled, int preset);
AEC_EXPORT int aec_reverse(void* handle, const int16_t* pcm, int samples);
AEC_EXPORT int aec_capture(void* handle, const int16_t* pcm, int16_t* out, int samples, int delay_ms);
AEC_EXPORT void aec_reset(void* handle);
AEC_EXPORT void aec_destroy(void* handle);
#ifdef __cplusplus
}
#endif
