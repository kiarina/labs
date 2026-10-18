# Android speaker and standalone AEC bridge

The Android `aec_audio` plugin owns an `AudioTrack` output, never an
`AudioRecord` input. `record` owns capture and supplies raw PCM16, 48 kHz, mono.
Do not enable record's echo cancellation, noise suppression or gain control
for the standalone AEC condition. Use `AudioInterruptionMode.none` so WebRTC's
audio-focus transitions do not pause record.

`configure {enabled, delayMs}` creates the common AEC engine and a communication
usage speaker stream. Android 12+ explicitly selects the built-in speaker and
fails if selection is unavailable. `render {bytes}` enqueues up to 200 ms of PCM without blocking capture. A
dedicated audio-priority thread writes to the actual AudioTrack and passes only
accepted samples to the reverse reference. It supplies silence on underflow
and submits that same silence as reverse data, keeping the actual output and
AEC reference clocks together despite Dart scheduling jitter. Queue overflow
is an error. JNI independently buffers render/capture tails and processes exact
480-sample blocks.
`capture {bytes}` returns all newly completed cleaned blocks. The caller must
pair raw/processed samples using accumulated sample positions rather than assume
the returned bytes have the same length as that call's input.

`stopRender` clears the pending render queue; the small hardware buffer may
finish its already accepted samples (at most the configured AudioTrack buffer). It retains AEC adaptation. `reset`
clears capture/reverse tails and resets the AEC engine, and should only be used
at an explicit test boundary. `dispose` releases output/DSP and restores the
previous audio mode.

The plugin's `stats` reports actual AudioTrack playback-head frames, underruns,
speaker device type (2 is built-in speaker), and Android's active recording
configurations. Observe these configurations in idle and send phases: unchanged
recording session IDs support that record stays open and WebRTC adds no capture
session. Availability and visibility of recording configurations are subject to
Android permissions; missing visibility is not evidence of zero capture.
Do not treat the `captureBackend` implementation description as runtime audit.

JNI and Java are lab-local sources. The standalone engine and dependencies live
in the new lab's `native/` directory; do not modify a pub cache or the earlier
external-capture lab. Software AEC output is supplied to that lab-local external
WebRTC input with its physical microphone path disabled.

## Verification status

Java source compiled against the actual Flutter 3.47.2 embedding and Android SDK
36. NDK 28.2 arm64 compiled/linked the full engine and JNI. Dynamic symbols of the
AEC library are limited to the five C ABI entry points. Other Android ABIs are
not built in this lab: the extraction CPU dispatch needs additional source-filter
adaptation for 32-bit x86. APK build and initial physical speaker/microphone trial
completed. The first render implementation accumulated blocking MethodChannel
writes; its invalid OFF-interval evidence is retained in
`results/android-acoustic-blocking-render.json`. The dedicated-thread acoustic measurements are recorded below. The separate remote-playback and sender-gate integration test also passed,
as recorded below.

## Physical results (Pixel 6, Android 17, arm64)

The final acoustic trial is `results/android-acoustic-trace.json`. Camera and
record were each started once. The microphone delivered at least 48 kHz of PCM
in every phase; camera rates were 28.3–30.7 fps. Maximum callback gaps were
78.4 ms (audio) and 84.4 ms (video). Android reported one unchanged recording
session (built-in microphone, client/device both 48 kHz, not silenced), while
all phase snapshots selected built-in speaker type 2. AudioTrack underruns were
zero. Voice-call volume was 7 of 15; the lab did not change it.

The final run used far signal peak bound 2250 / 32768 and digital near signal
peak bound 6000 / 32768. Both are synthesized, changing tones/chirps; the near
signal is added only to capture input, not physically spoken and not included
in the render reference. This distinguishes deterministic near-end preservation
from a future acoustic human-voice doubletalk test.

| Measurement | Far interval 1 | Far interval 2 | Doubletalk |
| --- | ---: | ---: | ---: |
| Overall raw/clean RMS attenuation | 5.11 dB | 7.09 dB | 6.86 dB |
| Correlated render-component reduction | 12.10 dB | 9.58 dB | 12.69 dB |

Near-only matched-signal gain was -0.33 dB; doubletalk near gain was -1.44 dB.
The near-only best alignment (432 samples, 9 ms) was reused for doubletalk.
This is not a claim that all real speech will receive the same treatment.

The correlated metric fits a scalar gain after optimizing lag against the
actual AudioTrack-accepted PCM, including inserted silence. Raw and processed
signals are fitted separately. It separates the render-correlated component
from some unrelated ambient energy, but is not full broadband ERLE and does
not model a frequency-dependent room impulse response. The Android bridge
keeps a bounded 120-second diagnostic render trace; truncation is reported in
stats. `tools/android_analyze_acoustics.py` computes these metrics from local
PCM artifacts and writes only numerical evidence plus hashes into Git.

`PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED` was false on the device, so the
comparison retained `AndroidAudioSource.mic` and explicitly reports that
fallback. No sample reached abs >= 32700 and injected near audio did not clip.
However, a small number of raw samples hit the same +/-26027 peak, and reducing
far PCM by four did not proportionally reduce microphone level. Uncontrolled
platform gain/limiting is a remaining hypothesis, not an established cause.
The earlier higher-output result is retained in
`results/android-acoustic-high-output.json`, and the low-output trial before
actual-render tracing is in `results/android-acoustic-low-output.json`.

The dedicated Android acoustic probe exercises physical playback, capture
continuity and the DSP without creating WebRTC peer connections. The common
`acoustic_probe.dart` supplies the final remote-playback and sender-gate
integration test documented below. The lab-local Android external
track source disables WebRTC echo cancellation, noise suppression, automatic
gain control and high-pass filtering so the standalone-DSP comparison does not
quietly apply a second WebRTC audio-processing stage.

The final JNI/Android transport source also passed the real Gradle
`:flutter_webrtc:compileDebugJavaWithJavac` target after disabling transport APM
flags. Android's standalone acoustic entry point is
`app/lib/android_aec_probe.dart`; build with
`flutter build apk --debug --target lib/android_aec_probe.dart --target-platform android-arm64`.
Raw captured PCM remains device-local or in local temporary analysis files and
is not committed; result JSON records hashes for the analyzed PCM.

## Receiver routing and gate diagnostics

The common `app/lib/acoustic_probe.dart` additionally tests a dedicated
fixture-only WebRTC peer pair, routes its decoded remote PCM into the owned
speaker/AEC reference, then tests two clean-microphone/camera sender gates.
The Android lab patch calls `PeerConnection.setAudioPlayout(false)` immediately
after each native peer is created. This preserves decoding through WebRTC's
null audio poller while preventing a second, unreferenced native speaker path.
The patch compiled successfully and applies idempotently to the pristine pinned
flutter_webrtc package. The final foreground runtime trial passed as recorded below.

Two diagnostic attempts were invalidated by device foreground/lock conditions:
`results/android-gate-os-frozen.json` and
`results/android-gate-keyguard-locked.json`. Android reported the first process
as cached and frozen; a separate ADB-launched application was also observed.
The next attempt was behind the keyguard (`showing=true`, `occluded=false`).
Its microphone advanced and remote decoded audio arrived, but camera frames
stopped and background DSP throughput was insufficient. Both results correctly
report failure. They do not establish that the capture pipeline works while
locked or in the background.

The diagnostic recording with native playout disabled did receive 329,760 and
315,360 remote PCM samples (RMS 0.0334/0.0339), independently backed by 342/328
audio RTP packets and 328,800/314,880 decoded samples. This supports that disabling
native playout preserves remote decoding; full gate acceptance still requires
foreground camera/capture continuity. The activity now sets KEEP_SCREEN_ON and
logs lifecycle transitions, and platform stats report actual keyguard/device-lock
state. A locked device needs its owner to unlock it; the lab does not bypass
credentials or disable keyguard.

For a silent gate-only diagnostic build, use both
`--dart-define=SKIP_ACOUSTIC=true` and
`--dart-define=SKIP_REMOTE_FAR=true`. Skips are explicit in the result JSON.
For the final receiver-speaker plus gate trial, retain SKIP_ACOUSTIC=true but set
SKIP_REMOTE_FAR=false. That trial still produces about six seconds of physical
speaker audio and must be serialized with other acoustic tests.

## Final remote-speaker and sender-gate integration

After the owner unlocked the device, the foreground trial passed with
`SKIP_ACOUSTIC=true` and `SKIP_REMOTE_FAR=false`. This reused the completed
acoustic evidence instead of repeating the 39-second local-speaker trial.
The final evidence is `results/android-remote-far-gates.json`.

The fixture-only source sent 576,000 PCM bytes through a dedicated peer pair.
The independent remote tap delivered 313,440 samples (RMS 0.02365), backed by
329 inbound audio packets and 313,440 decoded samples. That decoded PCM went
to the owned AudioTrack and the same AEC render reference. The accepted render
trace contained 292,525 nonzero samples, peak 2747; Android reported built-in
speaker type 2, voice-call volume 7/15, no writer errors and zero underruns.
Clean microphone audio was processed continuously but was never sent into this
fixture source, preventing a microphone self-loop.

During that far phase, the same record input supplied 625,920 bytes, AEC produced
625,920 cleaned bytes, and the camera delivered 195 frames. Analysis of the
same raw/clean capture against the actual accepted speaker reference measured
5.79 dB overall RMS attenuation and 7.43 dB reduction in the optimally aligned
render-correlated scalar projection. The raw and cleaned projection correlations
were -0.295 and -0.245, respectively. This six-second receiver-playback test has
less adaptation time than the earlier warmed acoustic trial and is not a claim
of broadband ERLE. Raw abs >= 32700 clipping remained zero; the +/-26027 limiting
observation remains a constraint. The measured hardware-accepted versus
playback-head difference was 40 ms at the far-phase end snapshot.

The same microphone/camera/DSP then passed both clean-audio/video sender gates:

| Gate | Remote PCM samples | Remote PCM RMS | Remote video tap frames | Audio RTP packets | Video frames decoded |
| --- | ---: | ---: | ---: | ---: | ---: |
| send-1 | 318240 | 0.07862 | 184 | 333 | 185 |
| send-2 | 307680 | 0.08653 | 181 | 320 | 181 |

All three idle intervals continued source capture and injected zero audio/video.
Camera and record were each started once. The maximum observed source callback
gaps were 121.7 ms for audio and 236.4 ms for video. All 12 device snapshots
reported keyguard/device unlocked, one unchanged non-silenced recording session
(49417), built-in microphone type 15, client/device both 48 kHz, built-in speaker
type 2, zero speaker underruns and no writer errors. Thus WebRTC sending and
receiving did not replace record's active microphone session in this trial.
The patch also leaves WebRTC's physical AudioRecord input disabled.

The result includes `remoteFarPhase.acousticMetrics` and hashes for local PCM
artifacts. Raw microphone PCM remains local and is not committed. The application
was stopped after evidence collection; no further physical trials were run.
