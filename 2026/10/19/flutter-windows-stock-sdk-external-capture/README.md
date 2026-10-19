# Stock Windows SDK external capture feasibility

**No stock-SDK-only solution was established with the tested native APIs.**
Official prebuilt SDKs `.03` and `.05` both opened one extra SDK-owned microphone
capture client while the same `record` stream stayed alive. This lab independently
adapts the [external-capture probe](../flutter-webrtc-external-capture/README.md);
no earlier custom SDK, SDK patch/rebuild, API hook or browser backend was used.

## Result

| SDK / condition | Record-owned clients | SDK-owned clients initialized / started | Observation |
|---|---:|---:|---|
| .03 record only |1|0 /0|positive control for MF capture |
| .03 custom source/track only |1|0 /0|no audio transmission; not a solution |
| .03 ordinary SDK microphone |0|1 /1|positive control for SDK/DMO capture |
| .03 external input send |1|1 /1|isolation requirement failed |
| .03 explicit speaker selection |1|1 /1|same failure |
| .03 receiver track volume .5 |1|1 /1|same failure |
| .03 AEC/AGC/NS/HPF flags all requested false |1|1 /1|same failure |
| .03 muted → unmuted |1|1 /1|SDK started ~2.49s before unmute |
| .05 external input send |1|1 /1|latest official asset, same failure |

Counts represent unique successful capture clients, not duplicate lifecycle
views. The `record` and SDK clients had different AudioClient GUIDs and the same
capture-endpoint hash. SDK capture had a synchronous `MFWMAAEC.DLL` /
`libwebrtc.dll + RVA` call chain; record-only capture had MF/RTWorkQ callers.
Initialize and Start both succeeded. Every retained trial had ETW lost events0
and lost buffers0. Endpoint volume/mute did not change.

The real stock `record` package was used (no RAW fork). It started once and kept
producing PCM through source setup, negotiation and two sender-on/off gates.
Video was explicitly synthetic in these runs. Physical camera compatibility is not established; the
additional-microphone failure already disqualifies the requested conjunction.

### Independent media limitation

Audio RTP packets reached the native receiver and video decoded. **Audio decoded
PCM/tap callbacks remained0**, so full functional transport/practical audio
acceptance is false. Render-client initialization failed with `0x887c0030`.
Selecting the speaker through the published SDK API and changing only remote-track
volume0→.5 did not fix it. The OS format/settings were not changed to work around
it. This failure is retained separately and is not used to infer capture counts.
The extra successful SDK capture is a direct, independent negative observation.
This lab does not establish stock-SDK playout/AEC or conversational quality.

See [summary](results/summary.json), [source audit](docs/source-audit.md),
[observation criteria](docs/observation-criteria.md), and
[observer/control build and run](tools/windows/README.md).

## Meaning of the result

`kCustom`/`CaptureFrame` supplies external PCM, but does not disable the ADM's
recording lifecycle. The source contains separate eager initialization,
sending-stream start and unmute recording paths. The wrapper's four public
processing flags do not expose `init_recording_on_send`, `SetAudioRecording`,
or custom-ADM injection. Those are different controls from muting a track.
No relevant field-trial condition was found on the inspected recording branches.

The practical conclusion is limited to these official releases, public APIs and
hardware. It is not a proof about every future SDK or undocumented mechanism.
Encoding-inactive, inactive/replaceTrack and sendonly modes are implemented for
reproduction but **were not run**: source audit and active extra-capture evidence
met the stop condition. They must not be listed as successful runtime trials.

An upstream external-ADM API or supported recording-lifecycle suppression could
remove the need for a maintained custom DLL. Such an upstream change was not
implemented or submitted here. Standard SDK files and runtime code were unmodified;
ETW was an external observer, not an injected counter or capture blocker.

## Rules fixed before trials

- No rebuilt/patched WebRTC DLL, private-layout access to SDK implementation,
  browser/WebView backend, fake device or global microphone mute workaround.
- The lab's C++ Flutter plugin may use the published SDK custom-source API.
  Flutter registry access is required to register its tracks; the SDK ABI stays stock.
- Keep the same real `record` capture alive through sender-off/on transitions.
  Try a physical camera; if unavailable, explicitly report synthetic video and
  do not claim physical camera compatibility.
- Prove stock identity by official asset hash, loaded DLL hash and absent custom
  audit/playout exports. Absence of audit exports means **unavailable**, not zero.
- Independently observe OS capture with positive controls. A second SDK recording
  stream/client is a failure even if external-source RTP works. Incomplete
  observation yields inconclusive, never a zero-capture success.
- Muted/inactive/no-track conditions are controls, not solutions unless unmuted,
  real PCM/video RTP and decoded reception still work with no extra microphone.

Matrix: record-only; factory/custom-source-only; default sendrecv; muted→unmuted;
encoding inactive→active; sendonly; replaceTrack(null)→custom if source/API evidence
suggests a distinct path. Test the plugin's official SDK and latest official SDK
when compatible. Stop expanding variants after actual capture plus source evidence
establishes the shared unconditional initialization path and no public suppression.

The shipped package/tool versions are pinned to the preceding experiment to
isolate SDK behavior. A separate latest official SDK check addresses update-only
alternatives. No paid API or product integration is involved; raw microphone PCM
is not published.

## Reproduce

Use Flutter3.47.2/Dart3.13.2, flutter_webrtc1.6.2+hotfix.4, record7.1.2 /
record_windows2.3.0 and the lockfile. These package pins isolate SDK behavior from
the preceding lab; the separate `.05` official-SDK trial addresses a version-only
update. The ordinary plugin SDK is `.03`. Both original ZIP/DLL hashes and URLs
are recorded in [official-sdks.json](results/official-sdks.json).

Run `python3 tools/prepare.py`, then `flutter pub get` and
`flutter build windows --release` from `app/`. The binary is `stock_capture_app.exe`.
For `.05`, use a separate vendor/build tree with its official ZIP, headers and
import library, and update its local version manifest together; do not merely
relabel a `.03` DLL as `.05`.

Run each mode in a new interactive process, with observer trace active before
launch. Set `STOCK_VARIANT`, `STOCK_MIC=DualSense`, `STOCK_CAMERA_MODE=synthetic`,
`STOCK_EXPECTED_SHA256` to the official DLL hash and `STOCK_EXIT=true`.
Optional public-API variants: `STOCK_SELECT_PLAYOUT=1`, `STOCK_SPEAKER=EDIFIER`,
`STOCK_RECEIVER_VOLUME=0.5`, `STOCK_AUDIO_PROCESSING_OFF=1`.
The bridge refuses a different loaded hash or the custom lab audit/playout exports.

After private artifacts are collected:

```sh
python3 tools/assess_trial.py build/trials/03-external results/03-external.json \
  --sdk libwebrtc.m150.7871.03
mise run
```

`mise run` checks retained negative evidence and verifies that missing events or
wrong SDK identity cannot establish zero additional capture. It opens no devices.
Raw ETL/CSV/process metadata stays ignored in `build/`; public results normalize
paths to module basenames/RVAs and hash endpoint IDs. No PCM or video is saved.

The first xperf CSV dump was interrupted by shell stderr handling and recovered
from the same complete ETL. A mislabeled setup attempt still loaded `.03` and was
not counted as `.05`. A C++ index-conversion warning was fixed before retrying.
See the observer notes; none of these failures were relabeled as successful `.05`
or zero-capture trials. The final `.05` run used a separate header/importlib build
and its actual official DLL hash.
