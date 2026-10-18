# whisper_cpp on the web (WebAssembly)

The web backend (`lib/src/whisper_web.dart`) implements the same `WhisperEngine`
API as the native dart:ffi backend, with whisper.cpp v1.9.5 compiled to
WebAssembly (SIMD128, CPU only) and running in a Web Worker, so the UI thread
never blocks on inference. `lib/whisper_cpp.dart` picks it with
`export 'src/whisper_native.dart' if (dart.library.js_interop) 'src/whisper_web.dart';`.

## Layout

| Path | What |
| --- | --- |
| `lib/src/whisper_web.dart` | Dart side (`dart:js_interop` + `package:web`, no `dart:html`) |
| `web/whisper_wasm.cpp` | Small C entry point (`wjs_*` exports) over whisper.h |
| `web/whisper_worker.js` | Worker that loads the wasm module and owns the `whisper_context` |
| `web/strip_pthread_launcher.sh` | CMake compiler launcher used for the single-threaded build |
| `tool/build_web.sh` | Builds both wasm variants and stages them in `assets/whisper_web/` |
| `assets/whisper_web/` | Build outputs (gitignored except its `.gitignore`), declared as package assets |
| `web/serve.py` | Local static server, optional COOP/COEP headers |
| `web/harness/` | Plain-JS test page + headless Chrome runner (`run_headless.mjs`) |
| `example_web/` | Flutter web app that runs the Dart API end to end |

## Build

```sh
brew install emscripten            # macOS; tested with Emscripten 6.0.12
packages/whisper_cpp/tool/build_web.sh          # both variants
VARIANTS=st packages/whisper_cpp/tool/build_web.sh   # only one
```

The script runs `tool/fetch_whisper_cpp.sh` if `third_party/whisper.cpp` is
missing, builds the `whisper` + ggml static libraries with `emcmake cmake`
(`build/web/{st,mt}`), links `web/whisper_wasm.cpp` and writes:

| File | Size |
| --- | --- |
| `whisper_st.js` / `.wasm` | 62 KB / 1.22 MB |
| `whisper_mt.js` / `.wasm` | 78 KB / 1.26 MB |
| `whisper_worker.js` | copied from `web/` |

Link flags: `-O3 -msimd128 -sMODULARIZE -sEXPORT_NAME=createWhisperModule
-sENVIRONMENT=worker -sALLOW_MEMORY_GROWTH -sINITIAL_MEMORY=64MB
-sMAXIMUM_MEMORY=4GB -sSTACK_SIZE=5MB`; the mt variant adds `-pthread
-sPTHREAD_POOL_SIZE=Module.wjsPoolSize||4`.

Two details that the build depends on:

- `-DEMSCRIPTEN_SYSTEM_PROCESSOR=wasm32`. Emscripten's toolchain file reports
  `x86` by default; ggml does not recognise that, prints "Unknown CPU
  architecture" and builds ggml-cpu with `GGML_CPU_GENERIC`, without its wasm
  SIMD kernels.
- whisper.cpp's CMakeLists.txt always appends `-pthread` under Emscripten.
  Objects built that way need shared memory, which only exists on
  cross-origin isolated pages. The single-threaded build uses
  `web/strip_pthread_launcher.sh` as compiler launcher to drop the flag.

## Single- vs multi-threaded, and the headers

`WhisperEngine.load` picks the build in the worker:

- `crossOriginIsolated === true` → `whisper_mt` (pthreads, SharedArrayBuffer).
  The pool is pre-spawned at start-up with `min(hardwareConcurrency, 8) - 1`
  workers; `options.threads = 0` uses all of them plus the worker thread
  (8 threads on a 10-core machine). The pool has to be spawned up front:
  the worker thread blocks inside `whisper_full` and can't start new Workers
  while it does.
- otherwise → `whisper_st` (1 thread, works on any page, no special headers).

`WhisperEngine.variant = 'st' | 'mt' | 'auto'` (web only) forces a build.

To get the multi-threaded build the **page** must be served with:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp      # or: credentialless
```

- `flutter run -d chrome --cross-origin-isolation` (Flutter 3.47.2; a hidden
  flag listed by `flutter run --help -v`) adds COOP `same-origin` + COEP
  `credentialless`. It is on by default with `--wasm`. Arbitrary headers:
  `--web-header=Name=value` (also hidden) or `headers:` in
  `web_dev_config.yaml`.
- Static hosting (`flutter build web`): configure the two headers on the host
  (e.g. Firebase Hosting `headers`, Cloudflare Pages `_headers`, nginx
  `add_header`). With `require-corp`, every cross-origin subresource (CDN
  fonts, images, a model on another origin) needs CORP/CORS; `credentialless`
  is less strict. Hosts that can't set headers have to use the st build (or
  a service-worker shim like whisper.cpp's `examples/coi-serviceworker.js`,
  not tried here).
- Local: `python3 packages/whisper_cpp/web/serve.py --root <dir> --coi
  [--coep credentialless]`.

## Using it from a Flutter web app

1. Run `tool/build_web.sh` before `flutter build web` / `flutter run -d chrome`.
   `pubspec.yaml` declares `assets/whisper_web/`, so Flutter copies the files
   to `assets/packages/whisper_cpp/assets/whisper_web/`, and the default worker
   URL is resolved with `ui_web.assetManager.getAssetUrl(...)`. On a fresh
   checkout the folder holds only its `.gitignore`: native builds still work,
   but the web engine fails to load until the script has run. (The
   `.gitignore` is bundled as a tiny asset too.) The wasm assets also end up
   in native app bundles (about 2.6 MB).
2. To host the files somewhere else, set `WhisperEngine.workerUrl` (web
   only) before `load`; `whisper_st.*` and `whisper_mt.*` must be next to
   `whisper_worker.js`.
3. Model: `WhisperEngine.load(path: 'models/ggml-base.bin')`. On the web
   `path` is a URL, resolved against the page and fetched by the worker
   (the bytes don't go through Dart). `load(bytes: ...)` also works; the bytes
   are structured-cloned into the worker, so the caller's list stays usable.

## API differences from native

- `useGpu` is ignored (no WebGPU backend in this build).
- `threads`: 0 = all pre-spawned threads (mt) or 1 (st). Native 0 = whisper's
  default `min(4, cores)`. Values above the pool size are clamped.
- Web-only extras on `WhisperEngine`: static `workerUrl`, static `variant`,
  `loadedVariant`, `threads` (max per call), `modelFetchTime`,
  `modelInitTime`. App code that also builds for native must not use them
  without its own conditional import (`example_web` imports
  `src/whisper_web.dart` directly).
- `WhisperEngine.backend` is synchronous and reports the build that `load`
  would pick on this page: `whisper.cpp v1.9.5 (wasm32, SIMD128, CPU,
  multi-threaded|single-threaded)`. `systemInfo` is empty until the first
  `load`, then e.g. `WHISPER : ... | CPU : WASM_SIMD = 1 | REPACK = 1 |`.
- `fitAudioCtx` / `minAudioCtx` are honoured (`audio_ctx` goes to
  `whisper_full_params`).
- Text decoding matches native: segment text is trimmed, and the full text is
  decoded from the joined bytes because one UTF-8 character can be split
  across two segments.

## Verification

### Setup

- Input: `work/conversation_16k.wav` (14.17 s, two Japanese speakers, 16 kHz
  mono s16). Language `ja`, greedy, `noContext`, `suppressNonSpeech`,
  temperature 0, full audio_ctx unless noted.
- Models: `ggml-{tiny,base,small,medium}.bin` from
  `huggingface.co/ggerganov/whisper.cpp`, served locally from the lab's
  gitignored `models/whisper/`.
- Browser: Chrome 155.0.8059.80, headless (`--headless=new`), driven by
  `web/harness/run_headless.mjs` over CDP.
- Machine: Apple M1 Max (10 cores, 64 GB), macOS. **Other agents were building
  and testing on the same machine during the runs (1-min load average 5 to 15,
  and up to about 190 in one window, noted below).** Absolute times are noisy;
  the st/mt and audio_ctx comparisons were run back to back.
- Toolchain: Emscripten 6.0.12, Flutter 3.47.2 (dart2js release build;
  one dart2wasm check), whisper.cpp v1.9.5.

How to reproduce (from the lab root):

```sh
packages/whisper_cpp/tool/build_web.sh
python3 packages/whisper_cpp/web/serve.py --root . --port 8787 &        # st
python3 packages/whisper_cpp/web/serve.py --root . --port 8788 --coi &  # mt
node packages/whisper_cpp/web/harness/run_headless.mjs \
  "http://127.0.0.1:8788/packages/whisper_cpp/web/harness/?model=base&runs=3"
# Flutter app:
(cd packages/whisper_cpp/example_web && flutter build web --release \
  --base-href /packages/whisper_cpp/example_web/build/web/)
node packages/whisper_cpp/web/harness/run_headless.mjs \
  "http://127.0.0.1:8788/packages/whisper_cpp/example_web/build/web/?runs=2&model=../../../../../models/whisper/ggml-base.bin"
```

### Results: plain-JS harness (one transcription = whole 14.17 s file)

`whisper_full` time per call, runs 1/2/3 (the 1st call is always slower).
"Load" = fetch from localhost + `whisper_init`.

| Model | Build | Threads | Load (fetch + init) | Run 1 / 2 / 3 (ms) |
| --- | --- | --- | --- | --- |
| tiny | st | 1 | 120 ms (53 + 50) | 9229 / 9307 / 9226 |
| tiny | mt | 4 | 210 ms | 3158 / 2490 / 2462 |
| tiny | mt | 8 | 171 ms (48 + 74) | 2070 / 1669 / 1520 |
| base | st | 1 | 166 ms (95 + 58) | 21789 / 21593 / 22051 |
| base | mt | 4 | 266 ms | 6906 / 5851 / 5718 |
| base | mt | 8 | 265 ms (85 + 110) | 4301 / 3117 / 3127 |
| small | st | 1 | 355 ms | 87519 |
| small | mt | 8 | 545 ms (253 + 239) | 14668 / 12708 |
| medium | mt | 8 | 1500 ms (767 + 679) | 47537 / 41624 |

Earlier runs while the machine was more heavily loaded gave tiny mt 8:
2.9 s, base mt 8: 6.7 s, tiny mt 2: 4.9 s, tiny mt 6: 2.8 s, base st: 24.2 s.
So the mt numbers move by up to 2x with background load; st moves less.

Wasm linear memory after init / after a call (the reserved heap, not live
use): tiny 662 / 662 MB, base 660 / 756 MB, small 1051 / 1147 MB, medium
2282 / 2282 MB.

Text (2nd call, same for st and mt except one word in tiny):

- tiny: もしもしもう息についた?うん、今開発出たところ。そこは、こっちをあまだ電車、あと5分くらいかな?理解、じゃあカフェの前で待ってるね。確かで今日は結構寒いね。本当、マフラー持ってきて正解だった。
  (mt 8 threads printed 一気 for 息: the thread count changes the float
  summation order)
- base: もしもしもう駅についた?うん今開発出たところそちら?こっちはまだ電車あと5分くらいかな?理解じゃあカフェの前で待ってるね助かれ今日は結構寒いねほんとまふら持ってきて正解だった
- small: もしもしもう駅についた うん今解説出たところそっちはこっちはまだ電車あと5分くらいかな了解じゃあカフェの前で待ってるね 助かる今日は結構寒いねほんとマフラー持ってきて正解だった
- medium: もしもしもう駅に着いた?うん、今改札出たところそっちは?こっちはまだ電車、あと5分くらいかな了解、じゃあカフェの前で待ってるね助かる今日は結構寒いねほんとマフラー持ってきて正解だった

### Results: Flutter web app (`example_web`, the Dart API)

| Model | Build | Load (Dart, total) | whisper ms, runs 1/2/3 | Max frame gap during calls |
| --- | --- | --- | --- | --- |
| tiny | st | 120 ms | 9390 / 9335 / 9225 | 16 ms |
| tiny | mt 8 | 159 ms | 2232 / 1565 / 1568 | 16 ms |
| base (`load(bytes:)`) | st | 227 ms | 25858 / 23309 / 22612 | 16 ms |
| base (`load(bytes:)`) | mt 8 | 331 ms | 5401 / 4150 / 4320 (load avg ~190) | 16 ms |
| tiny, COEP `credentialless` | mt 8 | 157 ms | 2332 / 1756 (load avg ~180) | 16 ms |
| tiny, `--wasm` (dart2wasm) | mt 8 | 219 ms | 2559 / 2048 (load avg ~160) | 16 ms |
| base, `--wasm` (dart2wasm) | mt 8 | 258 ms | 5242 / 4231 (load avg ~160) | 16 ms |
| tiny, default asset URL, `fitAudioCtx` | mt 8 / st | 157 / 111 ms | 1203 / 1201 · 6298 / 5696 | 16 ms |

"Max frame gap" is the longest gap between `requestAnimationFrame` callbacks
while `transcribe` was pending; 16 to 17 ms means the UI kept 60 fps. One
run showed a single 33 ms gap. The text matches the harness output.

### audio_ctx (`WhisperOptions.fitAudioCtx`), mt 8 threads

Back to back, 3 runs each, `whisper_full` ms:

| Input | Model | audio_ctx 0 (full 1500) | fitted | Text |
| --- | --- | --- | --- | --- |
| 14.17 s | tiny | 1863 / 1527 / 1289 | 832: 1164 / 1048 / 983 | a few words changed (りょかい, さないね) |
| 14.17 s | base | 4046 / 2924 / 2957 | 832: 2636 / 1865 / 1795 | almost the same (マフラン) |
| first 2 s | tiny | 1551 / 1185 / 1089 | 256: 615 / 385 / 405 | **changed**: もしもしもう一気に来た → もしもしもしもしも大きいフィーター。 |
| first 2 s | base | 3510 / 2552 / 2538 | 256: 664 / 454 / 450 | identical: もしもしもう息に吹いた? |

Fact: in wasm, a fitted audio_ctx makes short utterances 3 to 6x faster
(the encoder always runs over 30 s otherwise) and long ones about 1.5x faster.
Interpretation: worth it for VAD utterances of 0.5 to 15 s, but tiny at
256 frames started to hallucinate on this sample; base stayed stable. Not
checked on more samples.

### Memory and model size (wasm32, 4 GB max)

- The model is read into whisper through a `whisper_model_loader` that pulls
  chunks from the JS `ArrayBuffer` (`Module.wjsReadModel`), so the heap never
  holds a second full copy of the file next to the tensors. The JS
  ArrayBuffer is outside the wasm heap and is dropped after init.
- Measured: tiny, base, small and medium all load and transcribe with
  `MAXIMUM_MEMORY=4GB`. medium takes 2.28 GB of linear memory.
- Speed sets the practical limit, not memory: with mt 8 on this machine,
  base runs at about 0.2 to 0.3x real time on a 14 s clip, small at about
  0.9x (12.7 s for 14 s), medium at about 3x (42 s). st is about
  0.65x (tiny) and 1.6x (base) real time, so on the st build only tiny keeps
  up with live speech. For live use on the web: tiny or base, on the mt build,
  with `fitAudioCtx`.
- large (3 GB f16) was not tried: model + compute buffers would exceed or come
  close to 4 GB. Quantized models (q5/q8) would need less memory, also not tried.

## Failures along the way

- First build used Emscripten's default `CMAKE_SYSTEM_PROCESSOR` (`x86`):
  ggml fell back to `GGML_CPU_GENERIC`. Fixed with
  `-DEMSCRIPTEN_SYSTEM_PROCESSOR=wasm32` (no before/after timing recorded).
- pthread Workers: in a classic worker, Emscripten starts pthreads with
  `new Worker(self.location.href, {name: 'em-pthread'})`, which is
  `whisper_worker.js`, not `whisper_mt.js` (Emscripten 6 has no
  `mainScriptUrlOrBlob`). `whisper_worker.js` therefore checks
  `self.name === 'em-pthread'` and only `importScripts('whisper_mt.js')`.
- medium first returned 6 segments with correct timestamps but **empty
  text**: with a heap above 2 GB, pointers returned by wasm exports are
  negative JS numbers. Fixed with `>>> 0` on every returned pointer.
- `window.result = map.jsify()` from dart2js did not show up for the CDP
  reader. The example publishes `window.resultJson` (a string) instead. Cause
  not investigated.

## Open issues

- No WebGPU: ggml has a WebGPU backend, not tried here; `useGpu` is ignored.
- Safari/Firefox not tested; only Chrome 155 (headless) on macOS.
- Mobile browsers not tested (memory limits per tab are much lower than 4 GB).
- Timings were taken while other jobs loaded the machine; re-measure on an
  idle machine before quoting absolute numbers.
- The pool size (`min(hc, 8) - 1`) was not tuned; 4 vs 8 threads differs by
  about 1.6x for tiny and 1.8x for base here.
- No service-worker COOP/COEP shim for hosts that can't set headers.
