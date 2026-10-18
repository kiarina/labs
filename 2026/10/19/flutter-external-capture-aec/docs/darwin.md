# Apple output and standalone AEC

`AVAudioEngine` + `AVAudioSourceNode` opens output only. It does not access
`inputNode`: `record` owns the microphone and `camera_desktop` / `camera` owns
video. Source-node PCM, including zero-filled underflows, feeds AEC3 reverse;
`record` chunks are accumulated into 480-sample capture frames. AEC3 adds no
NS/AGC. Sending can be gated after this processing.

The generated SwiftPM `AecCore` is a private-namespace ARM64 build. Run
`python3 tools/prepare_aec.py` before Flutter dependency resolution/builds.
Intel Mac / iOS simulator compilation has not been established. The physical
Apple tests use ARM64; an ARM64-only Xcode build is required by this extraction's
current source selection.

## macOS physical result

MacBook Pro M1 Max 64 GB, macOS 27, built-in microphone and built-in stereo
speakers at 48 kHz. `results/macos-acoustic.json` contains one 39 s run with
8 phases and a single camera/record start. The camera delivered 1166 frames;
maximum audio gap was 109.1 ms and video gap 58.1 ms. There were no app errors
or mixed PCM clipping. Output-reference trace includes zero fills; its
underflow count also includes intentionally silent phases, so it is not a
standalone glitch-rate metric.

With the actual source-node reference and lag alignment, far-only correlated
echo reduction was 11.78 dB and 22.87 dB across the two playback periods.
Double-talk correlated echo reduction was 8.75 dB. Capture-only synthetic
near-end gain was −0.21 dB both near-only and double-talk. Whole-signal RMS
attenuation was 5.65/10.76 dB in far-only; it includes room noise and is not
labelled ERLE. This establishes short physical echo reduction with synthetic
near preservation; real human near speech, device switches, Bluetooth and
long clock drift are untested.

The source/render timelines have a ~2.48 s offset because output begins before
camera startup and record's first callback. Offline analysis aligns actual
render samples to captured samples; it does not assume enqueue time equals
speaker presentation time. The engine's delay hint is 80 ms.

Build the configured Flutter target for ARM64:

```sh
cd app
flutter build macos --release --config-only -t lib/acoustic_probe.dart
xcodebuild -workspace macos/Runner.xcworkspace -scheme Runner \
  -configuration Release -arch arm64 -derivedDataPath build/macos \
  -clonedSourcePackagesDirPath build/macos/SourcePackages
EXTERNAL_EXIT=true open -W build/macos/Build/Products/Release/external_aec_app.app
```

PCM is written to the app's private temporary directory and must remain local.
Copy/rename `aec_result.json` to `report.json` and `aec_*.pcm` to `*.pcm` inside
an ignored artifact directory, then run:

```sh
uv run --with numpy --with scipy python tools/analyze_acoustics.py \
  build/macos-acoustic results/macos-acoustic.json
```

The full probe also keeps these same sources open while a dedicated peer
pair carries a far-only fixture through Opus/RTP/remote PCM into the owned
speaker. During that phase microphone PCM is processed but never injected,
avoiding a microphone feedback loop. A separate pair then tests clean/camera
send gating twice. The lab's custom Darwin ADM discards its default playout;
only the owned player renders the received PCM.

The integrated Mac run in `results/macos-rtc-integrated.json` completed without
errors: 313,920 decoded far samples (RMS 0.0221) reached the owned player and
both clean/camera send gates passed. Actual-render correlated echo reduction
in its short remote-far phase was 26.58 dB. The repeated local-fixture far
periods measured 14.34/16.42 dB and digital near gain −0.21/−0.21 dB. These
separate runs illustrate room/fixture variability and are both retained.
One intervening launch timed out waiting for microphone permission/startup;
`results/macos-startup-permission-timeout.json` preserves that failure. A fresh
launch completed; the timeout cause is not established.

## iOS

The output session is `playAndRecord`, default mode, default-to-speaker,
48 kHz preferred rate. Input remains owned by `record`, with echo cancellation,
noise suppression and automatic gain disabled. iPad Air 4 / iPadOS 27.0.1, built-in mic and speaker: the 39 s acoustic
run completed with camera and record started once, 937 video frames, maximum
audio gap 132.6 ms / video gap 54.3 ms, no app errors or mixed clipping.
`results/ios-acoustic.json` includes acoustic results and subsequent cleaned
PCM/camera WebRTC gate tests. Two send periods decoded both audio and video;
idle periods injected nothing while acquisition and DSP continued.

Actual-render correlated echo reduction was 12.81 / 30.89 dB in far-only and
8.40 dB in double-talk. Capture-only near gain was −0.20 dB near-only and
−1.12 dB double-talk. Whole-signal far-only RMS attenuation was 8.71 / 22.51 dB;
these physical values include noise and are not ERLE. Real human near-end
speech remains untested. Route descriptions in the retained report are
normalized to port types rather than device addresses/names.

The initial run did not produce an observable result before it was stopped.
The diagnostic version persists each startup/phase/cleanup step and bounds
native awaits to 20 s; the subsequent run completed. The initial cause was not
established, and its lack of a report is not counted as a successful run.

The iOS remote-only follow-up (`results/ios-rtc-integrated.json`) explicitly
skips the already completed local acoustic phases. The same camera/record
sources remain open through remote far playback and both clean send gates.
It received 313,920 far PCM samples (RMS 0.0224), passed both send gates with
no app errors, and measured 14.17 dB correlated echo reduction in the short
remote-playback phase. Maximum source gaps were audio124.6/video53.3 ms.

iOS leaves the result screen open after saving: terminate this lab's process
with `devicectl` after collecting artifacts. Calling the C runtime `exit(0)`
on the device stalled during global WebRTC teardown in the integrated test;
the sources, peer pairs and AEC player had already been explicitly disposed
and the result saved. Automatic `EXTERNAL_EXIT` is therefore desktop-only in
the common probe. The result screen uses a short status rather than full JSON.
