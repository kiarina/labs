# whisper_cpp

A Flutter plugin that runs [whisper.cpp](https://github.com/ggml-org/whisper.cpp)
(local Whisper ASR) on raw 16 kHz mono Float32 PCM. It is the ASR stage of the
lab's real-time microphone pipeline: a VAD cuts utterances (typically 0.5–15 s)
and each utterance is passed to `WhisperEngine.transcribe`. The model is loaded
once and reused. There is no file decoding or ffmpeg.

| Platform | Implementation | Acceleration |
|---|---|---|
| macOS | dart:ffi, CocoaPods + whisper.cpp CMake | Metal (shaders embedded) + Accelerate BLAS |
| iOS (device) | same | Metal + Accelerate BLAS |
| iOS simulator | same | CPU + Accelerate (Metal turned off, see below) |
| Android | dart:ffi, Gradle `externalNativeBuild` (CMake) | CPU (NEON), arm64-v8a + x86_64 |
| Windows | dart:ffi, CMake | CPU (AVX2), x64 |
| Web | WebAssembly (`lib/src/whisper_web.dart`, `web/`) | separate part of the lab, not covered here |

## API

```dart
import 'package:whisper_cpp/whisper_cpp.dart';

final engine = await WhisperEngine.load(path: '.../ggml-base.bin'); // useGpu: true
final r = await engine.transcribe(pcm16kMono,               // Float32List, [-1, 1]
    options: const WhisperOptions(language: 'ja'));         // 'auto' also works
print('${r.language} ${r.elapsed.inMilliseconds} ms ${r.text}');
for (final s in r.segments) print('${s.start}-${s.end} ${s.text}');
await engine.dispose();
print(WhisperEngine.backend); // whisper.cpp v1.9.5 (Metal, Accelerate BLAS, CPU)
```

- `lib/src/whisper_types.dart`: `WhisperSegment`, `WhisperResult`, `WhisperOptions`
  (defaults: `language: 'ja'`, `threads: 0` = whisper.cpp's default min(4, cores),
  `translate: false`, `noContext: true`, `suppressNonSpeech: true`,
  `temperature: 0`, `fitAudioCtx: false`, `minAudioCtx: 256`), and `WhisperException`.
  Pure Dart, shared with the web backend. `fitAudioCtx` sets whisper.cpp's
  `audio_ctx` from the utterance length (`audioCtxFor`) instead of the fixed
  30 s window: on a Pixel 6 a 1–2.5 s utterance went from ~4 s to 0.7–1.3 s
  with base, with some extra repetitions and misheard words.
- `lib/src/whisper_native.dart`: `WhisperEngine`.
  - Each engine spawns one long-lived background isolate that owns the
    `whisper_context*`. `load`, `transcribe` and `dispose` are messages to that
    isolate. They are queued on the Dart side and run one at a time, so the UI
    isolate never blocks on inference. PCM is passed as `TransferableTypedData`.
  - `transcribe` calls `whisper_full` with `WHISPER_SAMPLING_GREEDY` and reads
    segments with `whisper_full_n_segments` / `_get_segment_text` / `_t0` / `_t1`.
    whisper.cpp's default temperature fallback (+0.2 when the decode fails its
    entropy/logprob checks) stays on.
  - `WhisperResult.elapsed` is the time inside `whisper_full` only (measured in the
    worker isolate).
  - `dispose` calls `whisper_free` and kills the isolate. Later calls throw
    `WhisperException('engine disposed')`.
  - `load(bytes: ...)` also works on native platforms (`whisper_init_from_buffer_with_params`).
    The buffer is freed after init.
  - `WhisperEngine.backend` is built at compile time (`whisper_version()` plus the
    compiled-in `GGML_USE_*` backends). It deliberately does not touch the ggml
    backend registry, because initializing the registry creates the Metal device
    and compiles shaders. That work belongs inside `load` on the background isolate.
  - Additions beyond the planned API: `WhisperEngine.systemInfo` (`whisper_print_system_info`).
    It may initialize the ggml backends, so call it after a `load`.
    `WhisperException` is also new.
- `src/whisper_cpp.c` / `.h`: a small C shim (`wcpp_*`). Dart never mirrors
  `whisper_full_params` / `whisper_context_params`, because their layouts change
  between releases. Logging from whisper.cpp/ggml is limited to errors unless
  the environment variable `WHISPER_CPP_LOG=1` is set.

## whisper.cpp source

Pinned to **whisper.cpp v1.9.5**, the latest GitHub release on 2026-10-18,
published 2026-10-06. The source is not vendored. To fetch it:

```sh
packages/whisper_cpp/tool/fetch_whisper_cpp.sh
```

The script downloads `https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v1.9.5.tar.gz`,
checks sha256 `ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720`,
and extracts the source to `third_party/whisper.cpp` (gitignored). Every native
build needs this step.

Models: `tool/download_models.sh [base] [small] [medium]` downloads
`ggml-*.bin` from `huggingface.co/ggerganov/whisper.cpp` into the lab's
gitignored `models/whisper/`. The script checks each file's sha256 against the
LFS oid (base `60ed5bc3…`, small `1be3a9b2…`, medium `6c14d5ad…`; full values
are in the script).

## Build flags per platform

All platforms build whisper.cpp + ggml through whisper.cpp's own CMake
(`src/CMakeLists.txt` → `add_subdirectory(third_party/whisper.cpp)`). The
libraries are static and linked into one plugin binary. The shared settings are
`BUILD_SHARED_LIBS=OFF`, `GGML_NATIVE=OFF` (never `-march=native`),
`GGML_OPENMP=OFF` (ggml's own thread pool), `GGML_BACKEND_DL=OFF`,
`WHISPER_BUILD_IS_DEV=OFF` (the release tarball otherwise reports `1.9.5-dev`),
and no examples, tests, server or curl.

- **macOS / iOS** (`macos/` and `ios/whisper_cpp.podspec`): a CocoaPods
  `script_phase` (before compile) runs `tool/build_apple.sh`. The script runs
  CMake with a clean environment for Xcode's `$PLATFORM_NAME` (macosx /
  iphoneos / iphonesimulator) and `$ARCHS`, in Release, with
  `GGML_METAL=ON GGML_METAL_EMBED_LIBRARY=ON GGML_METAL_USE_BF16=ON GGML_BLAS=ON
  GGML_BLAS_VENDOR=Apple GGML_ACCELERATE=ON`. It then `libtool`s every archive into
  `$(TARGET_TEMP_DIR)/whisper_cmake/lib/libwhisper_all.a`. That archive is linked
  into `whisper_cpp.framework` together with the shim (`Classes/whisper_cpp.c`
  forwards to `../src/whisper_cpp.c`). Deployment targets: macOS 14.0, iOS 15.6.
  The script needs `cmake` (it adds `/opt/homebrew/bin` and `/usr/local/bin` to
  `PATH`). `ENABLE_USER_SCRIPT_SANDBOXING=NO` is set on the pod. A universal
  macOS release (`arm64;x86_64`) builds. The x86_64 slice has no AVX flags
  because of `GGML_NATIVE=OFF` and was not run. In the example app the macOS
  App Sandbox is turned off so that it can read model and WAV paths from
  anywhere.
- **Android** (`android/build.gradle`): `externalNativeBuild` → `src/CMakeLists.txt`,
  `abiFilters "arm64-v8a", "x86_64"`, `-DANDROID_STL=c++_static`, `-O3` for every
  variant (AGP otherwise uses `-O0` for debug), `-Wl,-z,max-page-size=16384`,
  `-Wl,--exclude-libs,ALL -Wl,--gc-sections`. CPU only. arm64 uses the armv8-a
  baseline (NEON). Adding
  `-P whisper_cpp.armArch=armv8.2-a+dotprod+fp16` (or putting the key in the
  app's `android/gradle.properties`) sets `GGML_CPU_ARM_ARCH`. That build is
  faster but no longer loads on cores older than ARMv8.2 (for example
  Cortex-A53/A73). x86_64 (emulator) leaves out AVX, AVX2, FMA, F16C and BMI2.
  NDK: Flutter's default `ndkVersion`, which was 28.2 here. CMake: the SDK's
  3.22.1.
- **Windows** (`windows/CMakeLists.txt` → `src/CMakeLists.txt`): x64 only
  (`CMAKE_SYSTEM_PROCESSOR` AMD64), `GGML_AVX=ON GGML_AVX2=ON GGML_FMA=ON
  GGML_F16C=ON GGML_BMI2=ON`, BLAS, Vulkan and CUDA off. Output: `whisper_cpp.dll`
  with the static whisper/ggml inside. The shim exports through
  `__declspec(dllexport)`. **Vulkan** (`GGML_VULKAN=ON`) is the realistic GPU
  option on Windows: it would need the Vulkan SDK (glslc) at build time and
  `vulkan-1.dll` at runtime. It is not enabled here.

## Measured results

Input: `work/conversation_16k.wav`, a two-speaker Japanese conversation of
14.17 s (16-bit PCM, mono, 16 kHz). Options: `language: 'ja'`, defaults
otherwise, greedy, threads = whisper.cpp default (4). Each row is one fresh
process (one model per launch). The process runs `load`, then `transcribe` 3×
on the same engine, then `dispose`. Times are the time inside `whisper_full`
reported by `WhisperResult.elapsed`. The wall time measured on the UI isolate
was within 1–10 ms of it. Model files were in the OS page cache, so load times
are warm-cache times.

### macOS: Apple M1 Max MacBook Pro (64 GB), macOS 27.0.1, `flutter build macos --release`

| model | backend | load | run 1 | run 2 | run 3 |
|---|---|---:|---:|---:|---:|
| base | Metal | 109 ms | 249 ms | 215 ms | 215 ms |
| small | Metal | 246 ms | 411 ms | 478 ms | 553 ms |
| medium | Metal | 770 ms | 1042 ms | 1000 ms | 992 ms |
| base | CPU + Accelerate (`useGpu: false`) | 87 ms | 441 ms | 433 ms | 426 ms |
| small | CPU + Accelerate | 193 ms | 1196 ms | 1182 ms | 1189 ms |
| medium | CPU + Accelerate | 510 ms | 3051 ms | 3049 ms | 3028 ms |

`backend` = `whisper.cpp v1.9.5 (Metal, Accelerate BLAS, CPU)`.

- First Metal use after a fresh build: in the very first launch, ggml compiled
  the 35 embedded Metal libraries in **5.4 s** (`ggml_metal_library_compile_all:
  loaded 35 libraries from embedded data in 5.375 sec`). In that first build the
  `backend` getter initialized the ggml registry, so the compile ran on the UI
  isolate. That bug is fixed: the getter is now compile-time. In later launches
  the same step took **0.018 s**. Interpretation (not verified): macOS caches
  the compiled shaders per binary, so a user may pay roughly 5 s on the first
  `load` after installing or updating the app.
- The first `transcribe` in that very first process took 841 ms (base, Metal),
  compared with about 230 ms afterwards. Later processes show only a small cold
  penalty for run 1.
- Transcripts (identical on Metal and CPU):
  - base: `もしもしもう駅についた?うん今開発出たところそちら?こっちはまだ電車あと5分くらいかな?理解じゃあカフェの前で待ってるね助かれ今日は結構寒いねほんとまふら持ってきて正解だった`
  - small: `もしもしもう駅についた うん今解説出たところそっちはこっちはまだ電車あと5分くらいかな了解じゃあカフェの前で待ってるね 助かる今日は結構寒いねほんとマフラー持ってきて正解だった`
  - medium: `もしもしもう駅に着いた?うん、今改札出たところそっちは?こっちはまだ電車、あと5分くらいかな了解、じゃあカフェの前で待ってるね助かる今日は結構寒いねほんとマフラー持ってきて正解だった`
  - Base makes clear errors (開発/改札, 理解/了解, 助かれ, まふら). Small fixes
    most of them but keeps 解説. Medium was correct on this clip, by
    inspection only: there is no reference transcript or CER here.
- Base produced 11 segments with plausible timestamps, for example
  `[0.00-2.00] もしもしもう駅についた?`.
- Model reuse: `load` ran once per process and the three `transcribe` calls
  reused the context. Logs with `WHISPER_CPP_LOG=1` show `whisper_init` only
  once. `dispose` took 5–24 ms, and a `transcribe` after `dispose` throws
  `WhisperException('engine disposed')`. Freed memory was **not** measured
  separately (no RSS tracking).

### iOS

- `flutter build ios --simulator --debug` and `flutter build ios --no-codesign
  --release` (device, arm64) both succeed. The plugin framework exports all 12
  `wcpp_*` symbols.
- Simulator (iPhone 17, iOS 27.0 runtime, on the M1 Max): with Metal on, the app
  crashed in `whisper_init` (`ggml_metal_buffer_set_tensor` →
  `MTLSimDevice newBufferWithLength:…` → `_xpc_api_misuse`, SIGTRAP). The shim
  now forces `use_gpu=false` when `TARGET_OS_SIMULATOR`. After that change, base:
  load 135 ms, runs 1899 / 1877 / 2158 ms, with the same text as macOS.
- A real iPhone or iPad was **not** run. The Metal path on device is therefore
  unverified.
- **Static pod linkage drops the entry points.** An app that uses
  `use_frameworks! :linkage => :static` (flutter_onnxruntime requires it) linked
  none of the `wcpp_*` symbols: nothing references them, since dart:ffi looks
  them up at run time, and `transcribe` then waited forever. The podspec now
  copies `libwhisper_all.a` next to the pod's product and adds
  `user_target_xcconfig` `-Wl,-u,_wcpp_…` plus `-lwhisper_all`, which keeps the
  shim and pulls whisper.cpp from the archive (with dynamic frameworks the
  symbols come from the framework as before). Found and checked in the lab's
  app on the iOS 27 simulator.

### Android: Pixel 6 (Tensor G1), Android 17, debug APK (native code is `-O3`; JIT Dart does not affect `whisper_full`)

| model | arm64 build | load | run 1 | run 2 | run 3 |
|---|---|---:|---:|---:|---:|
| base | baseline armv8-a (default) | 434 ms | 5092 ms | 5078 ms | 5112 ms |
| small | baseline armv8-a (default) | 376 ms | 19136 ms | 21796 ms | 21367 ms |
| base | `armv8.2-a+dotprod+fp16` | 485 ms | 4506 ms | 4257 ms | 4713 ms |
| small | `armv8.2-a+dotprod+fp16` | 666 ms | 10371 ms | 11548 ms | 11524 ms |

- The text matches macOS for each model. `systemInfo` is `NEON = 1 | ARM_FMA = 1 | REPACK = 1`
  for the baseline build and adds `FP16_VA = 1 | DOTPROD = 1` for the v8.2 build.
- The runs were back to back without cooling, so thermal state is not
  controlled. Interpretation: on this phone, base needs about 0.3× real time and
  small with v8.2 needs about 0.8× real time. Small on the baseline build is
  slower than real time.
- `flutter build apk --release --target-platform android-arm64,android-x64`
  succeeds. Each ABI contains `libwhisper_cpp.so` (arm64 1.7 MB, x86_64 2.0 MB).
  A plain `flutter build apk` also succeeds but still packages `armeabi-v7a`
  without `libwhisper_cpp.so`. On a 32-bit-only device, `load` throws.
- Android emulator: not run (the device was available).
- Model and WAV were copied into the app's files dir with `adb shell run-as`,
  which is why a debug APK was used.

### Windows

Built and run later from the lab's app (not `example/`) on a Core i9-12900K
desktop with MSVC 14.38 (VS 2022), `flutter build windows --profile`, CPU
(AVX2): base, 4 threads, ~0.7 s per 1–2.5 s utterance, 0.19–1.06 s with
`fitAudioCtx` (`../../results/replay-windows*.json`). The original checklist
for `example/`:

1. `tool/fetch_whisper_cpp.sh` in Git Bash. It needs `curl`, `tar` and
   `sha256sum`. Git for Windows' `core.autocrlf=true` does not affect the
   tarball.
2. `flutter build windows --release` in `example/`. Confirm that MSVC
   (VS 2022+) compiles ggml with `/arch:AVX2`, the C shim compiles as C, and
   linking a C target against C++ static libs works.
3. `whisper_cpp.dll` is next to the exe and `dumpbin /exports` lists the 12
   `wcpp_*` symbols.
4. Run with
   `set WHISPER_MODELS_DIR=…& set WHISPER_WAV=…& set WHISPER_BENCH_EXIT=1`
   and record the load and transcription times and the text.
5. A Debug `flutter run` builds the native code at `/Od`, so expect it to be
   very slow. Measure with `--profile` or `--release`.
6. Optional: rebuild with `GGML_VULKAN=ON` (Vulkan SDK installed) and compare.
7. ggml documents that clang-cl builds are usually faster than MSVC on Windows.
   Compare if CPU time matters.

## Commands

```sh
cd packages/whisper_cpp
tool/fetch_whisper_cpp.sh            # once
tool/download_models.sh base small medium

cd example
# macOS (release). Paths via environment; WHISPER_USE_GPU=0 forces CPU.
flutter build macos --release
LAB="$(cd ../../.. && pwd)"
WHISPER_MODELS_DIR="$LAB/models/whisper" WHISPER_WAV="$LAB/work/conversation_16k.wav" \
WHISPER_MODELS=base WHISPER_BENCH_EXIT=1 \
  build/macos/Build/Products/Release/whisper_cpp_example.app/Contents/MacOS/whisper_cpp_example

# iOS
flutter build ios --simulator --debug \
  --dart-define=WHISPER_MODELS_DIR="$LAB/models/whisper" \
  --dart-define=WHISPER_WAV="$LAB/work/conversation_16k.wav"   # host paths work in the simulator
flutter build ios --no-codesign --release

# Android (APK; values for the on-device run are passed with --dart-define)
flutter build apk --release --target-platform android-arm64,android-x64
P=dev.kiarina.labs.whisper_cpp_example; D=/data/user/0/$P/files
flutter build apk --debug --target-platform android-arm64 \
  --dart-define=WHISPER_MODELS_DIR=$D --dart-define=WHISPER_WAV=$D/conversation_16k.wav \
  --dart-define=WHISPER_MODELS=base,small --dart-define=WHISPER_BENCH_OUT=$D/bench.json
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb push "$LAB/models/whisper/ggml-base.bin" "$LAB/work/conversation_16k.wav" /data/local/tmp/
adb shell run-as $P mkdir -p files
adb shell run-as $P cp /data/local/tmp/ggml-base.bin /data/local/tmp/conversation_16k.wav files/
adb shell am start -n $P/.MainActivity && adb logcat -s flutter:I

# Windows (on a Windows machine)
flutter build windows --release
```

The example reads `WHISPER_MODELS_DIR`, `WHISPER_MODELS` (comma list, default
`base`), `WHISPER_WAV`, `WHISPER_LANGUAGE` (`ja`), `WHISPER_USE_GPU` (`1`),
`WHISPER_BENCH_OUT` (JSON path) and `WHISPER_BENCH_EXIT` from the environment,
falling back to `--dart-define`. It prints one `WHISPER_BENCH {json}` line per
model.

## Failures and open issues

- The iOS simulator's Metal crashes inside ggml (see above), so the simulator
  runs on the CPU.
- About 5 s of Metal shader compilation on the first launch after a build
  (observed once). `load` absorbs it, but a UI should show a loading state.
- macOS x86_64 slice and Android x86_64 were built but not run.
- 32-bit Android (`armeabi-v7a`) is not built.
- The CocoaPods script phase runs on every Xcode build (`always_out_of_date`).
  The CMake rebuild is incremental, about 1 s when nothing changed. A clean
  build compiles whisper.cpp in about 20–60 s per platform slice.
- Flutter 3.47 warns that the plugin has no Swift Package Manager support. It
  falls back to CocoaPods, which still works today. A future Flutter may require
  SwiftPM.
- `flutter build` did not rerun `pod install` after a podspec edit. Run
  `pod install` in `example/macos` or `example/ios` after changing the podspec.
- Not measured: memory (RSS) per model, accuracy (CER) against a reference
  transcript, short utterances (0.5–2 s, where Whisper's fixed 30 s encoder
  window dominates the cost), and threads other than 4.
