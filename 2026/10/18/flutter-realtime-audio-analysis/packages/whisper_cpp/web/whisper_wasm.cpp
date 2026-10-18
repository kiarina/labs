// Minimal C entry point for whisper.cpp compiled to WebAssembly.
//
// Called from web/whisper_worker.js (inside a Web Worker) through the
// exported `_wjs_*` symbols. Pointers are wasm32 addresses (JS numbers).
// Built by tool/build_web.sh in two variants: single-threaded (no
// SharedArrayBuffer needed) and multi-threaded (pthreads, needs
// cross-origin isolation).

#include "whisper.h"

#include <emscripten.h>

#include <cstdio>
#include <cstring>
#include <string>

namespace {

int g_log_level = GGML_LOG_LEVEL_WARN;
int g_last_level = GGML_LOG_LEVEL_INFO;

void log_cb(enum ggml_log_level level, const char * text, void *) {
    if (level != GGML_LOG_LEVEL_CONT) g_last_level = level;
    if (g_last_level >= g_log_level) fputs(text, stderr);
}

std::string g_lang;

struct JsModelReader {
    size_t pos;
    size_t total;
};

}  // namespace

// Copies the next `n` model bytes into `dst`; implemented in whisper_worker.js.
EM_JS(unsigned int, wjs_js_read_model, (void * dst, unsigned int n), {
    return Module.wjsReadModel(dst, n);
});

extern "C" {

// 0: debug, 1: info, 2: warn (default), 3: error
EMSCRIPTEN_KEEPALIVE void wjs_set_log_level(int level) {
    static const int map[] = {GGML_LOG_LEVEL_DEBUG, GGML_LOG_LEVEL_INFO, GGML_LOG_LEVEL_WARN, GGML_LOG_LEVEL_ERROR};
    g_log_level = map[level < 0 ? 0 : (level > 3 ? 3 : level)];
    whisper_log_set(log_cb, nullptr);
}

EMSCRIPTEN_KEEPALIVE const char * wjs_system_info(void) {
    return whisper_print_system_info();
}

// Loads a ggml model that lives in a JS Uint8Array (not in the wasm heap).
// whisper reads it through a model loader that pulls chunks via
// Module.wjsReadModel(dst, n), so the heap never holds a second full copy of
// the file next to the tensors (matters for small/medium in a 4 GB heap).
// Returns 0 on failure.
EMSCRIPTEN_KEEPALIVE whisper_context * wjs_init(unsigned int total_size) {
    whisper_log_set(log_cb, nullptr);
    JsModelReader reader{0, total_size};
    whisper_model_loader loader{};
    loader.context = &reader;
    loader.read = [](void * ctx, void * out, size_t n) -> size_t {
        auto * r = static_cast<JsModelReader *>(ctx);
        const size_t left = r->total - r->pos;
        if (n > left) n = left;
        if (n == 0) return 0;
        const size_t got = (size_t) wjs_js_read_model(out, (unsigned int) n);
        r->pos += got;
        return got;
    };
    loader.eof = [](void * ctx) -> bool {
        auto * r = static_cast<JsModelReader *>(ctx);
        return r->pos >= r->total;
    };
    loader.close = [](void *) {};
    whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = false;  // CPU backend only in this wasm build.
    return whisper_init_with_params(&loader, cparams);
}

EMSCRIPTEN_KEEPALIVE void wjs_free(whisper_context * ctx) {
    if (ctx) whisper_free(ctx);
}

// Runs whisper_full on 16 kHz mono float PCM. audio_ctx > 0 shrinks the
// encoder context (WhisperOptions.audioCtxFor). Returns whisper_full's code
// (0 = success).
EMSCRIPTEN_KEEPALIVE int wjs_full(
        whisper_context * ctx, const float * pcm, int n_samples, const char * language,
        int n_threads, int translate, int no_context, int suppress_nst, float temperature,
        int audio_ctx) {
    if (!ctx) return -100;
    whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    p.print_progress   = false;
    p.print_realtime   = false;
    p.print_special    = false;
    p.print_timestamps = false;
    p.n_threads        = n_threads < 1 ? 1 : n_threads;
    p.translate        = translate != 0;
    p.no_context       = no_context != 0;
    p.suppress_nst     = suppress_nst != 0;
    p.temperature      = temperature;
    if (audio_ctx > 0) p.audio_ctx = audio_ctx;  // 0 = full 1500 frames (30 s)
    g_lang = (language && *language) ? language : "auto";
    if (!whisper_is_multilingual(ctx)) g_lang = "en";
    p.language         = g_lang.c_str();
    p.detect_language  = false;
    return whisper_full(ctx, p, pcm, n_samples);
}

EMSCRIPTEN_KEEPALIVE int wjs_n_segments(whisper_context * ctx) {
    return whisper_full_n_segments(ctx);
}

EMSCRIPTEN_KEEPALIVE const char * wjs_segment_text(whisper_context * ctx, int i) {
    return whisper_full_get_segment_text(ctx, i);
}

// Segment times in centiseconds (whisper's native unit), as int32 to avoid
// BigInt at the JS boundary (int32 cs covers ~248 days).
EMSCRIPTEN_KEEPALIVE int wjs_segment_t0(whisper_context * ctx, int i) {
    return (int) whisper_full_get_segment_t0(ctx, i);
}

EMSCRIPTEN_KEEPALIVE int wjs_segment_t1(whisper_context * ctx, int i) {
    return (int) whisper_full_get_segment_t1(ctx, i);
}

EMSCRIPTEN_KEEPALIVE const char * wjs_lang(whisper_context * ctx) {
    const int id = whisper_full_lang_id(ctx);
    return id < 0 ? "" : whisper_lang_str(id);
}

}  // extern "C"
