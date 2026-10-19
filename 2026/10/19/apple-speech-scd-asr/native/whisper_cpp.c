// Thin C shim over whisper.h so that Dart never has to mirror the layout of
// whisper_full_params / whisper_context_params (they change between releases).
//
// All functions are called from one Dart background isolate per context; the
// shim itself keeps no global mutable state except the log switch and the
// backend description string (built once).

#include "whisper_cpp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "whisper.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#endif

// whisper.cpp / ggml logging: errors only, unless WHISPER_CPP_LOG=1 is set in
// the environment or wcpp_set_log_enabled(1) is called.
static int g_log_enabled = -1;

static void wcpp_log_cb(enum ggml_log_level level, const char* text, void* user_data) {
  (void)user_data;
  if (g_log_enabled < 0) {
    const char* e = getenv("WHISPER_CPP_LOG");
    g_log_enabled = (e && e[0] == '1') ? 1 : 0;
  }
  if (g_log_enabled || level == GGML_LOG_LEVEL_ERROR) {
    fputs(text, stderr);
  }
}

WCPP_API void wcpp_set_log_enabled(int enabled) {
  g_log_enabled = enabled;
  whisper_log_set(wcpp_log_cb, NULL);
}

static struct whisper_context_params wcpp_cparams(int use_gpu) {
  struct whisper_context_params p = whisper_context_default_params();
  p.use_gpu = use_gpu != 0;
#if defined(TARGET_OS_SIMULATOR) && TARGET_OS_SIMULATOR
  // The iOS simulator's Metal driver aborts inside ggml_metal_buffer_set_tensor
  // (newBufferWithLength:...pointer: -> _xpc_api_misuse, observed on the
  // iOS 27.0 simulator). Simulator builds run on the CPU (+ Accelerate).
  p.use_gpu = false;
#endif
  return p;
}

WCPP_API void* wcpp_init_from_file(const char* path, int use_gpu) {
  whisper_log_set(wcpp_log_cb, NULL);
  return whisper_init_from_file_with_params(path, wcpp_cparams(use_gpu));
}

WCPP_API void* wcpp_init_from_buffer(void* data, size_t size, int use_gpu) {
  whisper_log_set(wcpp_log_cb, NULL);
  return whisper_init_from_buffer_with_params(data, size, wcpp_cparams(use_gpu));
}

WCPP_API void wcpp_free(void* ctx) {
  if (ctx) whisper_free((struct whisper_context*)ctx);
}

WCPP_API int wcpp_transcribe(void* ctx, const float* pcm, int n_samples, const char* language,
                             int n_threads, int translate, int no_context,
                             int suppress_non_speech, float temperature, int audio_ctx) {
  struct whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
  if (n_threads > 0) p.n_threads = n_threads;
  p.translate = translate != 0;
  p.no_context = no_context != 0;
  p.suppress_nst = suppress_non_speech != 0;
  p.temperature = temperature;
  // >0 shrinks the encoder's context from 30 s (1500) to the audio's length;
  // much faster for short utterances, at some accuracy cost
  if (audio_ctx > 0) p.audio_ctx = audio_ctx;
  p.language = (language && language[0]) ? language : "auto";
  p.detect_language = false;  // "auto" already triggers detection inside whisper_full
  p.print_special = false;
  p.print_progress = false;
  p.print_realtime = false;
  p.print_timestamps = false;
  return whisper_full((struct whisper_context*)ctx, p, pcm, n_samples);
}

WCPP_API int wcpp_n_segments(void* ctx) {
  return whisper_full_n_segments((struct whisper_context*)ctx);
}

WCPP_API const char* wcpp_segment_text(void* ctx, int i) {
  return whisper_full_get_segment_text((struct whisper_context*)ctx, i);
}

WCPP_API int64_t wcpp_segment_t0(void* ctx, int i) {
  return whisper_full_get_segment_t0((struct whisper_context*)ctx, i);
}

WCPP_API int64_t wcpp_segment_t1(void* ctx, int i) {
  return whisper_full_get_segment_t1((struct whisper_context*)ctx, i);
}

WCPP_API const char* wcpp_result_language(void* ctx) {
  int id = whisper_full_lang_id((struct whisper_context*)ctx);
  const char* s = id >= 0 ? whisper_lang_str(id) : NULL;
  return s ? s : "";
}

static char g_backend[256];

// Compile-time description. Deliberately does not touch the ggml backend
// registry: initializing it creates the Metal device and compiles all
// embedded shaders (seconds), which belongs in model loading, off the UI
// isolate. The GGML_USE_* macros come from ggml's CMake (PUBLIC defines) or,
// on Apple, from the podspec.
WCPP_API const char* wcpp_backend(void) {
  if (g_backend[0]) return g_backend;
  const char* b =
#if defined(GGML_USE_METAL)
      "Metal, "
#endif
#if defined(GGML_USE_VULKAN)
      "Vulkan, "
#endif
#if defined(GGML_USE_CUDA)
      "CUDA, "
#endif
#if defined(GGML_USE_BLAS)
#if defined(__APPLE__)
      "Accelerate BLAS, "
#else
      "BLAS, "
#endif
#endif
      "CPU";
  snprintf(g_backend, sizeof(g_backend), "whisper.cpp v%s (%s)", whisper_version(), b);
  return g_backend;
}

WCPP_API const char* wcpp_system_info(void) {
  whisper_log_set(wcpp_log_cb, NULL);
  return whisper_print_system_info();
}
