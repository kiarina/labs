# Bounded streaming video decoding and Dart analysis

The long-video input architecture works on macOS, Windows, Android, iOS and Chrome for this H.264/AAC fixture. PCM and JPEGs reach the same Dart consumers before decoding finishes. Awaiting analysis applies backpressure instead of retaining all decoded media. Cancellation and a subsequent restart pass on all five targets.

This experiment follows the [short file-input lab](../flutter-ffmpeg-media-input/README.md) at commit `ebb4abb`. Its source and VAD subset were copied into this independent lab. It does not import a sibling lab or change product code. The measured workload is Silero VAD plus JPEG metadata validation, not ASR or semantic image understanding.

## Questions and method

Compare 60 and 600 media seconds, then slow the audio consumer, cancel after five consumed seconds, and restart. Measure first output, completion time, source reads on Web, pending analysis calls, JPEG buffer size, bounded result retention and memory. An additional macOS run processes the ten-minute input three times in one process to probe memory behavior across reuse.

The input is a reproducible repetition of the preceding shared 6.708-second clip, prepared with FFmpeg 9.0.2 (`-stream_loop -1 -t 600 -c copy -movflags +faststart`). It is 32,310,704 bytes; video duration is 600.107340 seconds and audio duration 600.007333 seconds. This is a repeated stress fixture, not ten minutes of varied content. The prepared input and model are ignored by Git. Their hashes and the toolchain are in [results/manifest.json](results/manifest.json).

## Results

Ten-minute case, one retained final suite per platform. Model loading and initial input preparation are excluded from the stream timings. Timing includes decoding, transport and real VAD inference. Native audio uses 100 ms or smaller analysis calls; Web uses the decoder's smaller AAC-derived events. Both use single-thread decoding; native ONNX uses two threads, Web one. These are feasibility measurements, not a controlled hardware ranking.

| Target | First PCM (ms) | First JPEG (ms) | Completion (s) | Sampled memory |
| --- | ---: | ---: | ---: | --- |
| macOS, M1 Max, release | 11 | 34 | 10.35 | 185.2 MiB whole-app RSS peak |
| Windows, Core i9-12900K, release | 13 | 35 | 9.37 | 189.6 MiB whole-app RSS peak |
| Pixel 6, profile | 26 | 67 | 48.74 | 380.3 MiB whole-app RSS peak |
| iPad Air 4, release | 11 | 42 | 14.75 | 120.7 MiB whole-app RSS peak |
| Chrome on M1 Max, release | 60 | 95 | 26.90 | 18.6 MiB decoder Wasm heap (not whole-browser RSS) |

All five targets delivered exactly 960,000 samples and 60 images for the one-minute case, and 9,600,000 samples and 600 images for ten minutes. The VAD-positive chunk counts were identical across platforms: 709 for one minute, 7,002 for ten minutes. Sample rounding and JPEG encoding are not bit-parity claims. The shared JPEG consumer checks dimensions/ordering and counts frames; it does not run an image AI model.

On Web, the first output arrives after 463,371 source bytes have been read (1.43% of the input). The source is mounted as a File through WORKERFS; no full-file `arrayBuffer()` or `FS.writeFile()` copy is used. Native first PCM arrives before the FFmpeg completion callback. Neither backend spools decoded PCM or images to temporary files.

### Slow consumer and cancellation

The slow case adds 25 ms per 100 ms of audio, scaled by payload length, so the artificial cost is independent of AAC/TCP packetization. The one-minute case finishes in 17.39 s on macOS, 16.97 s on Windows, 34.81 s on Pixel 6, 17.59 s on iPad and 19.09 s in Chrome. It still delivers all 960,000 samples and 60 images. Native producer completion also slows (macOS 5.22 s versus the normal one-minute pipeline at 1.08 s), demonstrating that delayed reads reach the producer rather than an unbounded application queue.

Only one audio analysis call is outstanding. Native PCM payloads are at most 3,200 bytes; the largest observed JPEG accumulation is 14,523 bytes, under a 256 KiB rejection cap. Web transfers one event and waits for the Dart consumer's acknowledgment before asking C for the next event. Its largest payload is around 14 KiB. Socket/kernel and FFmpeg internal buffers are additional bounded storage, not included in the Dart payload measurement.

Cancel after five consumed seconds interrupts native FFmpeg and destroys its sockets, or terminates the Web Worker. Native completion follows the cancellation request within 1–5 ms in these runs; the Web value measures issuing termination, not waiting for garbage collection. A six-second restart in the same app then succeeds. Cancellation may deliver slightly more than five seconds due to the current event; no retained run reached six seconds before cancellation.

### Memory and retained results

The consumers keep at most eight recent voice intervals and eight image metadata records, while total counters continue. VAD context is bounded by the eight-second maximum voice and short pre-roll. The C decoder retains only decoder state, a small PCM buffer and the current encoded image. Web's Wasm heap is 19,464,192 bytes for both one and ten minutes; the main-page JS heap is separate and varies with garbage collection.

Whole-app RSS is not constant. In the primary macOS run, one minute peaks at 179.5 MiB and ten minutes at 185.2 MiB; the ten-minute trace reaches a plateau around 185 MiB. Three consecutive ten-minute traversals in a fresh process peak at 183.7, 191.0 and 195.0 MiB. That modest growth remains unexplained; bounded queues do not prove the absence of a native/framework leak. Android RSS fluctuates substantially during GC (approximately 300–356 MiB at the recorded thirty-media-second points, with a higher sampled peak), rather than following the media duration monotonically. No hours-long soak or isolated native-heap analysis was performed.

Memory is sampled every 200 ms. Reports retain points around thirty media seconds plus the sampled peak; short transients may be missed. macOS/Windows/iOS/Android figures are whole-process RSS, while Web's decoder heap and main-page JS heap are different metrics and must not be directly ranked against them.

## Architecture

### Native Flutter

FFmpegKit min opens the existing bundled file directly and sends two outputs to loopback TCP sockets: mono 16 kHz PCM16 and selected MJPEG frames. The Dart readers await each consumer, naturally pausing socket reads. No FIFO shell command or separately installed FFmpeg is required. Android first copies its compressed APK asset into cache through an AssetManager stream with a 64 KiB buffer; the video is never loaded through Dart rootBundle. macOS/iOS/Windows use the physical bundled asset path. Input preparation precedes timing.

This fixture exposed an important clock issue: input `-t` alone produced 9,616,608 samples for a nominal 600 seconds. Adding output `-t` still did not establish a sample-count limit on the repeated AAC timestamps. The final graph is `aresample=16000,atrim=end_sample=N,asetpts=N/SR/TB`, with N equal to duration times 16,000. Native sample counts and VAD decisions then match the incremental Web decoder. Reduced pre-fix observations are retained in `results/initial-macos-input-limit-only.json` and `results/intermediate-macos-output-t-only.json` instead of being silently discarded.

PCM time is the normalized sample clock. Native JPEG times are the nominal `0.5+n` selection schedule, not original packet PTS. Web reports selected frame PTS. The source starts at zero and is effectively CFR; exact VFR, discontinuities, edit lists and nonzero-origin audiovisual synchronization remain outside this experiment.

### Flutter Web

JavaScript passes the selected File to a Worker. WORKERFS performs seekable reads backed by the File, without copying its full contents into Wasm. C exposes `open_decoder`, `next_event`, current event accessors and `close_decoder`. Each `next_event` returns one PCM or JPEG event. The Worker copies/transfers only that event and awaits acknowledgment before continuing. Restart uses a new Worker and decoder instance. The build is single-threaded and requires no SharedArrayBuffer for this decoder.

The custom FFmpeg 8.1.2 build excludes GPL/nonfree components. It uses libavformat, libavcodec, libswresample and libswscale, rather than the default GPL ffmpeg.wasm core. This is a small owned adapter, not FFmpegKitNext's JS API. There is no whole decoded-file buffer or output virtual filesystem to drain.

Sources: [Emscripten WORKERFS](https://emscripten.org/docs/api_reference/Filesystem-API.html#workerfs), [FFmpeg TCP protocol](https://ffmpeg.org/ffmpeg-protocols.html#tcp), [atrim/asetpts](https://ffmpeg.org/ffmpeg-filters.html#atrim), [native Flutter package](https://pub.dev/packages/ffmpeg_kit_flutter_new_min).

## Reproduce

Use Flutter 3.47.2 / Dart 3.13.2 and the checked-in locks, Emscripten 6.0.12 for Wasm, and FFmpeg 9.0.2 only for preparing the repeated fixture. Native apps bundle FFmpeg n8.1.2 via ffmpeg_kit_flutter_new_min 3.6.7. The earlier native baseline's version is retained deliberately to compare transport architectures without changing decoder/inference dependencies. Input/model/source hashes are verified; prepared media, weights, compiled libraries and Wasm are not committed.

```sh
mise run prepare
mise run                   # shared logic tests and retained-report assertions
mise run macos             # default: 60,600,slow,cancel,restart
STREAM_CASES=600,600,600 mise run macos
WIN_HOST=user@windows-pc mise run windows
ANDROID_SERIAL=<device> mise run android
mise run web               # http://127.0.0.1:8797, select app/assets/long.mp4
```

Web starts analysis after the file is selected. A `?cases=60,600` query can select a subset. `tools/select_video.mjs` uses a separate headless Chrome on debugging port 9797 to select the real disk File, rather than loading the video through HTTP or an ArrayBuffer. `tools/cdp.mjs` is an optional inspection helper. The server receives JSON reports at `/report` and writes `work/stream-report-web.json`.

Native reports are in `getApplicationSupportDirectory()/stream-report.json`; Android profile builds expose `files/stream-report.json` through `adb exec-out run-as dev.lab.streaming_input_lab cat files/stream-report.json`. For iOS use `flutter build ios --release --no-codesign` to verify compilation; configure your own signing team for device installation. The retained device run used an automatically signed development release, not an App Store archive. The public project deliberately contains no signing team. Windows uses an interactive one-shot task `StreamInputLab20261019`, which should be removed after the run. Actual environment details are in the manifest.

`tools/summarize.py` copies metrics-only reports from `work/` into `results/`. `tools/validate_reports.py` asserts exact sample counts, frame counts, matching VAD-positive counts, bounded result retention, early delivery and cancellation/restart on all five measured targets. Tests additionally cover PCM callbacks split at odd bytes, long-run result retention, split/coalesced JPEG markers, oversized input and truncation.

## Limits and next decision

The data supports adopting a bounded PCM/JPEG event interface, await-based backpressure, explicit cancellation and separate decoder backends. It does not establish complete production support for arbitrary media. Other codecs, malformed inputs, VFR/seek behavior, streaming HTTP/HLS/RTSP, Safari/Firefox, background mobile execution and heavy ASR/vision consumers were not tested. Loopback transport has OS buffers and per-app network entitlements; its memory is not identical to a direct FFI callback. Native queues can buffer ahead even while the Dart consumer is sequential.

The file fixture, including the browser's File source, is available locally before analysis. This is incremental reading of a seekable file, not download-as-you-watch validation. Frame validation is metadata-only. The current eight-second voice segmentation and eight-result retention are lab choices, not product policy. Before product integration, run a longer soak, decide the actual downstream analysis cost/queue policy, and establish the required timestamp and codec support. Distribution and LGPL linking/notices/source obligations remain a separate release concern.
