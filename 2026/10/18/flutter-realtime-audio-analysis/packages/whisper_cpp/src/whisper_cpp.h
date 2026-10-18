#pragma once

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#define WCPP_API __declspec(dllexport)
#else
#define WCPP_API __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

WCPP_API void wcpp_set_log_enabled(int enabled);
WCPP_API void* wcpp_init_from_file(const char* path, int use_gpu);
WCPP_API void* wcpp_init_from_buffer(void* data, size_t size, int use_gpu);
WCPP_API void wcpp_free(void* ctx);
// Returns 0 on success. pcm: 16 kHz mono float32 in [-1, 1].
WCPP_API int wcpp_transcribe(void* ctx, const float* pcm, int n_samples, const char* language,
                             int n_threads, int translate, int no_context,
                             int suppress_non_speech, float temperature, int audio_ctx);
WCPP_API int wcpp_n_segments(void* ctx);
WCPP_API const char* wcpp_segment_text(void* ctx, int i);
// Segment times in units of 10 ms.
WCPP_API int64_t wcpp_segment_t0(void* ctx, int i);
WCPP_API int64_t wcpp_segment_t1(void* ctx, int i);
WCPP_API const char* wcpp_result_language(void* ctx);
WCPP_API const char* wcpp_backend(void);
WCPP_API const char* wcpp_system_info(void);

#ifdef __cplusplus
}
#endif
