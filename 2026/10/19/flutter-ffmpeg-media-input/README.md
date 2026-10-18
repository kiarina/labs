# FFmpeg file and microphone inputs for one Dart analysis pipeline

## Purpose and acceptance criteria

Validate four boundaries independently: native FFmpegKit min on macOS/Windows/Android/iOS; a non-GPL FFmpeg WebAssembly decoder in a Worker called from Flutter; shared timestamped PCM/image processing; and record microphone PCM entering that same processor. Decode the same shared MP4, count/measure 16 kHz mono samples and 1 fps images, run real Silero VAD, cancel processing, and report errors. A successful build is not a successful run. Hardware microphone tests are distinguished from file replay and fake devices. Native and Web decoders may differ in rounding, delay and JPEG encoding.

The media input experiment follows [the audio analysis lab](../../18/flutter-realtime-audio-analysis/README.md). Its audio package is copied at a recorded commit and owned by this lab; it does not import the previous lab. No product-specific implementation is included.

## Status

The four input boundaries passed the short-fixture checks below. Long-media streaming and additional formats remain outside the demonstrated result. No commercial redistribution approval is implied by a successful decode.

## Results

All four boundaries worked. The native package decoded the input on macOS, Windows, Android and an iPad. Flutter Web called a custom LGPL FFmpeg Wasm decoder through JavaScript and a Worker. Both backends supplied actual PCM and JPEG bytes to the same Dart consumers. The microphone supplied PCM to that consumer on macOS (real device) and Chrome (file-backed fake microphone).

| Environment | Build tested | Decode (ms) | Silero processing (ms) | Audio samples | Images |
| --- | --- | ---: | ---: | ---: | ---: |
| macOS, M1 Max | Release | 43 | 114 | 107,520 | 7 |
| Windows x64 | Release | 54 | 114 | 107,520 | 7 |
| Pixel 6 | Profile | 220 | 752 | 107,520 | 7 |
| iPad Air 4 | Release | 73 | 144 | 107,520 | 7 |
| Chrome, M1 Max | Release, Wasm Worker | 247 | 65 | 107,520 | 7 |
| iPhone simulator | Debug, earlier image metadata-only consumer | 124 | 364 | 107,520 | 7 |

These are single short runs with loaded dependencies, not a benchmark distribution. Native decode time includes two FFmpeg sessions (audio then images); Web uses one demux/decode traversal. Silero timing excludes model loading and file decoding. CPU, build mode and inference backends differ, so compare feasibility rather than rank platforms.

Every file run yielded 210 complete VAD chunks, 79 positive chunks and the same two voice intervals: `[0, 1.26]` and `[1.28, 3.5]` seconds (padding included). RMS was 0.08479328 and peak 0.75506592; decoder rounding was not bit-identical across backends. Images were 256x256 with source presentation times 0.5, 1.5, …, 6.5 seconds. JPEG bytes differ because scaling/encoding paths differ; pixel parity was not asserted. The container duration is 6.708008 s, while decoded PCM is 6.72 s, so container duration alone must not determine the sample count.

### Microphone

- macOS: owner allowed the permission prompt, then approximately five seconds of real microphone input gave 79,754 samples (4.985 s), RMS 0.00523, eight VAD-positive chunks and one voice interval. The maximum pending callback count was recorded in the report. Audio was not saved; only metrics and intervals are retained.
- Chrome: record used the same input audio through `--use-file-for-fake-audio-capture`. Five seconds gave 78,762 samples, 79 VAD-positive chunks and two voice intervals. This tests the browser capture path, not a physical microphone. Chrome changed the timing/amplitude relative to file decoding. The fake microphone needed `--no-sandbox` in this test environment, as observed in the preceding lab.
- Native mic behavior on Windows, Android and iOS was not rerun here. The preceding lab covers additional microphone behavior; this lab makes no new claim about those physical microphones.

### Failures, cancellation and memory

Missing-input errors and cancellation of a running FFmpeg session passed on all four native OS targets. A Web Worker was terminated after its `decoding` notification, and an invalid input produced a decoder error. The shared consumer tests cover PCM callbacks split at odd byte boundaries and empty input.

The macOS whole-app peak RSS was 203 MiB (`time -l`, separate file run). Android after completion used approximately 213 MiB PSS / 330 MiB RSS (`dumpsys meminfo`, not peak). These include Flutter and ONNX; they are not the FFmpeg decoder's isolated memory. Other environments' peak memory and long-duration resource growth remain unmeasured.

## Reproduce

Use Flutter 3.47.2 / Dart 3.13.2 and the checked-in pubspec.lock. Model and input hashes, source provenance, Wasm size and environment details are in [results/manifest.json](results/manifest.json). Each lab is independent: the VAD subset was copied from the preceding lab, then reduced to the code exercised here. All inputs are public shared assets or a pinned public VAD model.

```sh
mise run prepare
mise run check
mise run macos             # file -> PCM/images -> shared consumers
MODE=mic mise run macos    # permission prompt, then five seconds; no audio saved
mise run android          # build; set ANDROID_SERIAL to also install/run
WIN_HOST=user@windows-pc mise run windows
mise run web              # Emscripten 6.0.12; build, serve http://127.0.0.1:8798
```

Web opens in automatic file mode; `/?mode=mic` runs a microphone test. Use the microphone button for a manual run. The Wasm and input/model files are generated/downloaded, ignored by Git and served as app assets. `tools/serve.py` saves Web JSON reports under `work/`. Native reports go to `getApplicationSupportDirectory()/report.json`; Android profile builds can retrieve `files/report.json` with `adb exec-out run-as dev.lab.media_input_lab cat files/report.json`. Native reports print numbered `MEDIA_REPORT` parts as a fallback.

For iOS, build `app` with `flutter build ios --release --no-codesign --dart-define=AUTO=file`, or configure your own signing team in Xcode for a device installation. The experiment used an automatically signed development release, not an App Store archive. The simulator command is `flutter build ios --simulator --debug --dart-define=AUTO=file`; install/launch `dev.lab.mediaInputLab` with simctl. iOS/macOS use Swift Package Manager. Do not add a copied CocoaPods Podfile on top of the generated SPM project.

The Windows script copies this lab to a dedicated temporary directory and schedules a one-shot interactive task. The app includes `/utf-8` for MSVC so the ONNX headers compile in a Japanese Windows environment. It does not rely on a separately installed ffmpeg command. Native libraries are downloaded during the build, then bundled in the app. Remove the task `MediaInputLab20261019` when finished.

`tools/cdp.mjs` is an optional headless Chrome helper using Node's built-in WebSocket; it connects to a lab Chrome on remote-debugging port 9798. Launch a separate Chrome profile, never the normal browsing profile. For the fake microphone, create a WAV in `work/` from the shared video, then launch Chrome with the fake-device, fake-UI and file-capture flags. This fixture conversion used a host ffmpeg only to prepare a test input; the app's file decode used the bundled/native or custom Wasm implementation.

## Implementation and licensing

- Native: ffmpeg_kit_flutter_new_min 3.6.7, FFmpeg n8.1.2. Audio is extracted as mono 16 kHz PCM16. Frames use `select=gte(t\,selected_n+0.5),scale=256:-2,showinfo` and VFR output; source PTS comes from showinfo, not a guessed frame index.
- Web: `web_decoder/decode.c` calls libavformat/libavcodec/libswresample/libswscale directly. `tools/build_web_decoder.sh` builds pinned FFmpeg 8.1.2 with GPL/nonfree/autodetection disabled, only the selected demuxer/codecs and one thread. This avoids distributing the GPL default ffmpeg.wasm core. The output is about 1.9 MB of Wasm plus its loader. It is a small custom adapter, not FFmpegKitNext or the ffmpeg.wasm JavaScript API.
- Dart: callback boundaries are independent of PCM sample and VAD frame boundaries. The consumer carries an odd byte, processes 512-sample VAD chunks and reports a short trailing partial chunk rather than pretending it was analyzed. The image consumer receives JPEG bytes and validates dimensions and monotonic PTS. It does not run an image AI model.

Native runtime `-buildconf` did not report `--enable-gpl` or `--enable-nonfree` on any target. The Web runtime reports LGPL 2.1-or-later, and its configure flags are recorded in the Web result. The native Flutter wrapper is LGPL 3.0. These checks are not a complete license audit: commercial distribution still requires corresponding source/build instructions, notices and applicable linking/relinking conditions (particularly on iOS). No compiled library, weight or input media is checked into this repository.

Sources: [native package](https://pub.dev/packages/ffmpeg_kit_flutter_new_min), [FFmpeg source](https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz), [FFmpeg license](https://ffmpeg.org/legal.html), [record](https://pub.dev/packages/record), [ONNX Flutter](https://pub.dev/packages/flutter_onnxruntime).

## Observed integration problems and remaining limits

- A manually copied CocoaPods configuration on top of a new SPM Flutter project failed with a Podfile.lock sandbox error. Removing the redundant CocoaPods integration resolved macOS and iOS builds.
- MSVC treated ONNX's non-ASCII header comments as an error on Japanese Windows; `/utf-8` resolved it.
- Android's first native AAR download took several minutes. This was build-time dependency retrieval, not decode latency. flutter_onnxruntime also emits a Kotlin Gradle Plugin migration warning with the current Flutter toolchain; it did not prevent this build.
- The fixture is a single short H.264/AAC MP4 starting at timestamp zero. HEVC, WebM/Opus, VFR, edit lists, nonzero or discontinuous timestamps, video-only/audio-only files and corrupt media are not covered. The minimal Web decoder intentionally requires both audio and video.
- The native file path decodes to temporary outputs before feeding analysis; the Web path transfers decoded outputs after decoding. Neither is yet bounded streaming for long media. Full-file PCM and seven JPEGs fit this test, but long recordings need incremental IO/backpressure and a bounded queue. The current microphone queue is measured during a five-second run, not a production queue policy.
- Web was run in Chrome only. Safari/Firefox, mobile browser memory and browser audio permission differences remain open. The decoder itself is single-threaded and does not require SharedArrayBuffer; this test server still supplies COOP/COEP for the overall inference environment.
- This experiment exercises real VAD and image metadata validation, not ASR, speaker recognition or semantic image inference. The preceding audio lab owns those model measurements. iOS release installation is not proof of an App Store-ready distribution.
