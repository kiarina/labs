// Web Worker that hosts whisper.cpp (WebAssembly) for lib/src/whisper_web.dart.
//
// Staged by tool/build_web.sh next to whisper_st.js/.wasm (single-threaded)
// and whisper_mt.js/.wasm (pthreads). Loaded with `new Worker(url)` (classic
// worker, importScripts).
//
// This same file is also the script of every pthread Worker of the
// multi-threaded build: Emscripten starts pthreads with
// `new Worker(self.location.href, {name: 'em-pthread'})`, and inside a
// worker `self.location.href` is this file, not whisper_mt.js. So when we are
// started as a pthread we only import the glue, which boots itself.
//
// Protocol (all replies carry the request `id`):
//   {cmd:'init', id, variant:'auto'|'st'|'mt', modelUrl?, modelBytes?, poolSize?, logLevel?}
//     -> {id, ok:true, variant, poolSize, maxThreads, systemInfo, fetchMs, initMs, heapBytes}
//   {cmd:'transcribe', id, pcm:ArrayBuffer(Float32), language, threads,
//    translate, noContext, suppressNonSpeech, temperature, audioCtx}
//     -> {id, ok:true, text, segments:[{t0Ms,t1Ms,text}], language, threads, elapsedMs, heapBytes}
//   {cmd:'dispose', id} -> {id, ok:true}
//   any failure -> {id, ok:false, error}
'use strict';

if (self.name === 'em-pthread') {
  importScripts('whisper_mt.js');
} else {
  let Module = null;
  let ctx = 0;
  let variant = null;
  let poolSize = 0;
  let queue = Promise.resolve();

  const utf8 = new TextDecoder('utf-8');
  const heapU8 = () =>
    Module.wasmMemory ? new Uint8Array(Module.wasmMemory.buffer) : Module.HEAPU8;

  // Pointers returned by wasm exports are signed i32 in JS; with a heap
  // above 2 GB (medium model) they come back negative, hence `>>> 0`.
  // Copies a NUL-terminated string out of the wasm heap as raw bytes.
  function cString(ptr) {
    ptr >>>= 0;
    const h = heapU8();
    let end = ptr;
    while (h[end] !== 0) end++;
    return h.slice(ptr, end);
  }

  async function loadModule(requested, requestedPool) {
    const mt = requested === 'mt' || (requested === 'auto' && self.crossOriginIsolated === true);
    if (mt && self.crossOriginIsolated !== true) {
      throw new Error('multi-threaded build needs crossOriginIsolated (COOP/COEP headers)');
    }
    variant = mt ? 'mt' : 'st';
    importScripts(`whisper_${variant}.js`);
    const hc = self.navigator.hardwareConcurrency || 4;
    // ggml uses n_threads-1 pthreads + this thread. Pool must be pre-spawned
    // because this thread blocks inside whisper_full and cannot start Workers.
    poolSize = mt ? Math.max(1, requestedPool || Math.min(hc, 8) - 1) : 0;
    Module = await self.createWhisperModule({
      wjsPoolSize: poolSize,
      print: (s) => console.log(s),
      printErr: (s) => console.warn(s),
    });
  }

  async function handle(msg) {
    switch (msg.cmd) {
      case 'init': {
        if (Module) throw new Error('already initialised');
        await loadModule(msg.variant || 'auto', msg.poolSize || 0);
        Module._wjs_set_log_level(msg.logLevel ?? 2);
        const t0 = performance.now();
        let bytes = msg.modelBytes ? new Uint8Array(msg.modelBytes) : null;
        if (!bytes) {
          const res = await fetch(msg.modelUrl);
          if (!res.ok) throw new Error(`model fetch failed: ${res.status} ${msg.modelUrl}`);
          bytes = new Uint8Array(await res.arrayBuffer());
        }
        const t1 = performance.now();
        // whisper pulls the file in chunks through Module.wjsReadModel
        // (see wjs_init in whisper_wasm.cpp); no full copy in the wasm heap.
        let off = 0;
        Module.wjsReadModel = (dst, n) => {
          heapU8().set(bytes.subarray(off, off + n), dst >>> 0);
          off += n;
          return n;
        };
        ctx = Module._wjs_init(bytes.length) || 0;
        Module.wjsReadModel = null;
        bytes = null;
        if (!ctx) throw new Error('whisper_init_with_params failed (not a ggml whisper model, or out of memory)');
        return {
          variant,
          poolSize,
          maxThreads: variant === 'mt' ? poolSize + 1 : 1,
          systemInfo: utf8.decode(cString(Module._wjs_system_info())),
          fetchMs: t1 - t0,
          initMs: performance.now() - t1,
          heapBytes: heapU8().length,
        };
      }
      case 'transcribe': {
        if (!ctx) throw new Error('not initialised');
        const pcm = new Float32Array(msg.pcm);
        const maxThreads = variant === 'mt' ? poolSize + 1 : 1;
        const threads = Math.max(1, Math.min(msg.threads > 0 ? msg.threads : maxThreads, maxThreads));
        const pPcm = Module._malloc(pcm.byteLength) >>> 0;
        const pLang = Module.stringToNewUTF8(msg.language || 'auto');
        if (!pPcm) throw new Error(`malloc(${pcm.byteLength}) failed`);
        try {
          new Float32Array(heapU8().buffer, pPcm, pcm.length).set(pcm);
          const t0 = performance.now();
          const rc = Module._wjs_full(
            ctx, pPcm, pcm.length, pLang, threads,
            msg.translate ? 1 : 0, msg.noContext ? 1 : 0, msg.suppressNonSpeech ? 1 : 0,
            msg.temperature ?? 0, msg.audioCtx | 0);
          const elapsedMs = performance.now() - t0;
          if (rc !== 0) throw new Error(`whisper_full failed: ${rc}`);
          const n = Module._wjs_n_segments(ctx);
          const segments = [];
          const parts = [];
          for (let i = 0; i < n; i++) {
            const raw = cString(Module._wjs_segment_text(ctx, i));
            parts.push(raw);
            segments.push({
              t0Ms: Module._wjs_segment_t0(ctx, i) * 10,
              t1Ms: Module._wjs_segment_t1(ctx, i) * 10,
              text: utf8.decode(raw).trim(),
            });
          }
          // A multi-byte character can be split across two segments, so the
          // full text is decoded from the joined bytes (same as the native side).
          const all = new Uint8Array(parts.reduce((a, p) => a + p.length, 0));
          parts.reduce((o, p) => (all.set(p, o), o + p.length), 0);
          return {
            text: utf8.decode(all).trim(),
            segments,
            language: utf8.decode(cString(Module._wjs_lang(ctx))),
            threads,
            elapsedMs,
            heapBytes: heapU8().length,
          };
        } finally {
          Module._free(pPcm);
          Module._free(pLang);
        }
      }
      case 'dispose': {
        if (ctx) Module._wjs_free(ctx);
        ctx = 0;
        return {};
      }
      default:
        throw new Error(`unknown cmd ${msg.cmd}`);
    }
  }

  self.onmessage = (e) => {
    const msg = e.data;
    // Serialise requests: whisper_full is not re-entrant on one context.
    queue = queue.then(async () => {
      try {
        const r = await handle(msg);
        self.postMessage({ id: msg.id, ok: true, ...r });
      } catch (err) {
        self.postMessage({ id: msg.id, ok: false, error: String(err && err.stack || err) });
      }
    });
  };
}
