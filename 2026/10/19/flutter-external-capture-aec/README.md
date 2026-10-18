# Always-on camera + record with speaker playback and AEC3

## Purpose and evaluation

Keep camera and microphone capture open while speaker playback, echo
cancellation and WebRTC sending can start and stop independently. Target
Windows, macOS, Android, iOS and Web. This is an independent continuation of
[external media input](../flutter-webrtc-external-capture/README.md); no product
code is changed.

The primary path is `record` raw PCM → standalone AEC3 → application analysis
and optional WebRTC input. The same PCM actually submitted/consumed by the
speaker output is supplied as AEC render reference. Camera acquisition remains
active. Browser/OS AEC, if compared, is a separate condition rather than assumed
to cover arbitrary externally supplied PCM.

Before evaluation the digital acceptance targets were: far-only ERLE ≥15 dB;
near-only correlation ≥0.95 and gain within ±3 dB after delay alignment;
double-talk near-end gain ≥−6 dB and correlated echo improvement ≥6 dB. The
fixture uses independently seeded/uncorrelated far/near content, 80 ms echo
with gain 0.5, 18 s per scenario, and evaluates the last 3 s. A near signal is
added only to capture; playing it on the same referenced speaker would not
establish near-end preservation.

Physical speaker/microphone runs compare raw and cleaned PCM from **one
record capture**, measure camera/audio continuity and speaker/recording route,
and traverse speaker ON/OFF twice. Digital fixtures, actual acoustic paths,
near-end synthetic preservation and real human speech are distinct evidence.
No physical AEC success is inferred from fake microphone devices. Low raw
echo/silence makes a physical suppression result inconclusive rather than a
success. Sending is gated downstream of capture/DSP.

## Architecture

```text
camera ─────────────────────────────────── analysis / video track
record PCM48k mono ───┬── raw measurements
                     └── AEC3.capture ─── clean analysis / gate / WebRTC
speaker output ─── actual PCM reference ── AEC3.reverse
```

`native/aec_engine.h/.cc` defines a device-free 48 kHz mono PCM16 C API with
480-sample frames. The same extracted AEC3 is built for native platforms and
WebAssembly. The engine neither opens a microphone nor a speaker.

The extraction is pinned to
[Enaium/webrtc-aec3 `2cec2f5`](https://github.com/Enaium/webrtc-aec3/tree/2cec2f52e26646f93bd2d5498bbabf59cba18da9),
a BSD-3-Clause standalone source extraction. Its upstream WebRTC revision is
not declared by that repository, so this is not described as identical to the
m150 WebRTC transport SDK. `tools/prepare_aec.py` applies private C++ namespaces
to avoid collisions with flutter_webrtc's separate SDK. Generated sources and
binaries stay ignored. Full WebRTC transport/recording-isolation sources are
copied from the preceding lab and owned here independently.

## Current status

The device-free native/Wasm digital fixture passes with the same metrics at the reported precision:
far-only ERLE 61.43 dB, near-only correlation 0.9609 / gain −0.49 dB, and
double-talk near gain −5.10 dB / echo improvement 36.20 dB.

Short physical tests use real speakers/microphones, with capture-only synthetic
near-end injection. These figures describe correlated echo reduction after
alignment, **not** whole-signal ERLE or a human speech quality score.

| Platform | Far-only, two playback periods | Double-talk echo | Near gain, alone / double-talk | Evidence |
|---|---:|---:|---:|---|
| macOS, built-in mic/speaker | 11.78 / 22.87 dB | 8.75 dB | −0.21 / −0.21 dB | [Apple](docs/darwin.md) |
| Android, Pixel 6 | 12.10 / 9.58 dB | 12.69 dB | −0.33 / −1.44 dB | [Android](docs/android.md) |
| iOS, iPad Air 4 | 12.81 / 30.89 dB | 8.40 dB | −0.20 / −1.12 dB | [Apple](docs/darwin.md) |
| Web, Chrome real devices | 15.34 / 23.59 dB | 6.40 dB | −0.22 / −0.21 dB | [Web](docs/web-aec.md) |
| Windows, real mic / EDIFIER M60 | 11.18 / 7.59 dB (weak correlation) | 1.29 dB, inconclusive/insufficient | −0.21 / −0.21 dB | [Windows](docs/windows-aec.md) |

Windows uses synthetic video because no physical camera was available. Its
physical reference correlation is only 0.04–0.12, so the table is insufficient
to establish robust acoustic/double-talk cancellation there. Digital AEC,
received playback, clean sending and zero additional WebRTC recording are
verified independently.

The reports retain failed/high-output/blocking trials as well as successful
measurements. No raw microphone recordings are committed. Main-thread gaps,
underflows, device gain processing and the short fixture duration limit these
results. Per-platform docs distinguish local-fixture acoustics from WebRTC
receive/playout and sending-gate evidence.

## Integration coverage

| Platform | Continuous capture + local acoustic AEC | Decoded WebRTC far → owned speaker | Clean send gate twice |
|---|---|---|---|
| macOS | real camera/mic, measured | passed | passed |
| iOS | real camera/mic, measured | passed | passed |
| Web / Chrome | real camera/mic, measured | passed | passed; idle RTP delta 0 |
| Windows x64 | real mic / synthetic video; acoustic quality limited | passed | passed; extra recording audit 0 |
| Android ARM64 | real camera/mic, measured | implemented, final unlocked-device test pending | audio decoded with native playout off; full camera continuity pending unlocked-device test |

See the [evidence index](results/README.md) for every retained report, including
failures and the distinction between digital, fake-device and physical tests.

## Run

The default native app entry is `app/lib/acoustic_probe.dart`: continuous
capture/DSP, local speaker fixture ON/OFF, dedicated WebRTC far-fixture
encode/decode → owned speaker output, then two cleaned-PCM/camera send gates.
The default Web entry delegates to `web_rtc_probe.dart`, with a Start button for
the browser audio gesture. Standalone `web_acoustic_probe.dart` retains the
separate physical comparison procedure. Windows uses its dedicated
`windows_aec_probe.dart` entry to audit recording isolation and drive its custom
playout transport. See platform docs for build/run and artifact collection.

`mise run` validates the retained evidence. `mise run digital-native` rebuilds
and runs the deterministic C ABI test; `tools/web/test_aec.mjs` runs its Wasm
counterpart. Raw PCM artifacts stay in ignored build/private temporary folders.

## Prepare

```sh
python3 tools/prepare.py
python3 tools/prepare_aec.py
cmake -S native -B build/aec-macos -DCMAKE_BUILD_TYPE=Release
cmake --build build/aec-macos -j 8
python3 tools/build_wasm.py
```

Flutter 3.47.2 / Dart 3.13.2, record 7.1.2, camera 0.12.1,
camera_desktop 2.0.0, flutter_webrtc 1.6.2+hotfix.4. The lockfile records actual
Dart dependency versions. Windows keeps the audited recording-isolated SDK;
Android keeps external input with physical WebRTC microphone capture disabled.
Apple and Android physical tests currently target ARM64 devices.

## Boundaries

- Playback buffer timing, microphone chunk delay and independent capture/render
  clocks matter. Timestamp/delay statistics and underflows/overflows must be
  considered before attributing changes to AEC quality.
- AEC3 near-only/double-talk preservation is measured separately from global
  attenuation. The common engine does not add noise suppression or gain control.
- A successful short test is not a guarantee for Bluetooth, device changes,
  long-term clock drift, background operation or every browser/device.
- This experiment uses local fixtures and local WebRTC peers; no paid voice API
  or cloud transcription is needed.
