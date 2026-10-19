# Runtime validation of submitted core #314 and wrapper #158

This directory owns a fresh Windows runtime run of the submitted candidate,
separate from the parent's earlier f7e9-wrapper experiment. The DLL is
`73b672f90beba282e04ae6dd9dbcb7b3af574d192977ae9224c382075dbcd740`,
built with core commit `543b9cb70ee7b07311d4f4ddefc014278d6066d4` and wrapper
commit `f9a23f98e19c2784fd293941b9e67a43977f1635` (PRs #314 and #158).
It is a locally built candidate, not an official distributed SDK.

## Method and criteria

Use a fresh copy of this lab and matched candidate headers/import library/DLL.
Build the app against that SDK, keeping Flutter3.47.2/Dart3.13.2 and the existing
lockfile. Copy [main.dart](main.dart) over that copy's `app/lib/main.dart` to add
stop-window observations; the remaining app/plugins come from the parent lab.
Use `LAB_NATIVE_SOURCE` pointing to the matching native source for the existing
native-playout diagnostic. The DLL itself has no diagnostic mixer-pull or
capture-audit exports. All eight Windows wrapper source hashes were rechecked
against the submitted proposal before collecting these results.

The app keeps record PCM acquisition and synthetic Windows camera frames active,
while toggling injection, track.enabled and replaceTrack(null)/restore. Two
four-second sending windows are separated by two-second off windows. For each
off window, discard the first second of decoder/tap backlog, then poll PCM and
RTP counters for one second. Require no injected audio/video during off, positive
raw audio/video deltas throughout the off phase, off PCM RMS at most one PCM16
LSB (1/32768), and nonzero received PCM/video after both resumptions. Packet count
need not become zero: silence/comfort-noise RTP and decoder-clock output are
not live microphone content. Missing off PCM is separately visible in results.
These are short functional probes, not human speech-quality measurements.

Run eight separate processes with independent Windows Audio Client ETW:
record-only, normal microphone, external PCM with normal factory, external-only,
initially-muted external-only, then diagnostic playout-off with injection gates,
native track gates and replacement gates. Each trace must have lostEvents0 and
lostBuffers0, caller stacks, no unknown capture clients, unchanged endpoint
volume/mute and matching loaded DLL. Require positive SDK capture in the ordinary
factory controls and matching capture endpoints before accepting SDK capture0.
Capture initialization attempts and successful starts are counted separately.

The receiver volume remains zero. The playout-off diagnostic uses the standard
native SetAudioPlayout(false)/NullAudioPoller through source-matched wrapper
internals; it is not a public wrapper API or speaker/AEC validation. No microphone
PCM/WAV is saved or published. Raw ETL/CSV, app logs and endpoint snapshots stay
in ignored/private build directories. Public results contain counts, hashes,
module basenames and RTP statistics.

## Reproduce

From an elevated interactive Windows session, with a fresh lab copy and an
existing official05-header release directory retained from the predecessor's
build (do not rebuild that old executable/plugin):

```powershell
$env:UPSTREAM_MEASURE_STOPS='1'
# Put the existing ETW normalizer's Python executable on PATH.
& ./upstream/wrapper/runtime/run_suite.ps1 `
  -LabRoot '<fresh-lab-copy>' -LegacyRelease '<old-official05-release>'
```

`run_suite.ps1` and `run_abi.ps1` are parameterized versions of the orchestration
used for this run. They reuse the parent's tools/windows collector and refuse
to overwrite trial/ABI directories. Never cancel another WPR recording. Keep
`build-sdk-manifest.json` accurate and copy the candidate DLL into both the new
app release and a private copy of the old release. Every process checks the
loaded DLL identity; run_abi additionally records hashes of the unchanged old
executable and flutter_webrtc plugin, exit status, errors and endpoint state.
This exercises old no-argument factory/public interfaces, not exhaustive ABI.

For offline assessment, privately retain `sdk-manifest.json`, `abi-summary.json`
and `trials/<label>/` with normalized.json, upstream_input_result.json,
sdk-manifest.json, trial-policy.json and volume-before/after.txt:

```sh
python3 upstream/wrapper/runtime/assess.py <private-evidence> upstream/wrapper/runtime/results
python3 upstream/wrapper/runtime/verify.py
```

The verifier also rejects eight corrupted-evidence cases: trace loss, missing
positive SDK control, wrong DLL, extra SDK capture, missing resumed PCM, loud
off-window PCM, off-window injection and changed old executable identity.

## Results and limits

See [summary](results/summary.json), [old-binary exercise](results/abi.json) and
[build/provenance](results/build.json). Earlier runtime evidence is unchanged.
The wrapper's full 25-test pass and the core suite's shared 178 failures are
separate from these runtime trials. Physical Windows camera, speaker/AEC,
human double-talk, other devices/OS and long-duration stability remain outside
this run. Official SDK availability and public wrapper playout support remain
unresolved.

### Observed outcomes

| Process | record/MF starts | SDK capture attempts | Received PCM samples, on 1 / on 2 |
| --- | ---: | ---: | ---: |
| record-only | 1 | 0 | not exercised |
| native-mic-default | 0 | 1 | 0 / 0 |
| external-default | 1 | 1 | 0 / 0 |
| external-only | 1 | 0 | 0 / 0 |
| external-muted | 1 | 0 | 0 / 0 |
| external-native-playout-off | 1 | 0 | 238080 / 195360 |
| external-track-gates-playout-off | 1 | 0 | 238080 / 195360 |
| external-replace-gates-playout-off | 1 | 0 | 238560 / 195360 |

All eight traces have zero lost events/buffers and known capture caller stacks.
All five external-only variants retain record/MF1 and SDK capture attempts 0;
the ordinary external-input control has MF1 + SDK1. Endpoint volume/mute is
unchanged in every trial and in the ABI exercise.

In all six diagnostic off windows, received audio RTP packet delta is 0 and PCM
RMS is exactly 0 after settling. The decoder still delivers 48,480–48,960 zero
samples per off window. Both subsequent send windows have nonzero PCM RMS and
video, with RTP advancing again. Capture remains active and injection deltas
are 0 during off. Track/replace toggles each occur twice. The largest Dart raw
audio delivery gap in this run is 81.345ms; this is not a realtime-quality claim.

The unchanged old official05-header executable/plugin run with the new DLL:
exit 0, errors [], loaded hash matches. This confirms the exercised old binary
interfaces only. The old executable/plugin hashes match the earlier exercise.

**Unselected communications-default rendering still fails.** Its ETW render initialization result is
0x887c0030 (the previously diagnosed format failure); ordinary native-mic and
external trials decode 0 PCM samples. Only the separately labeled native-playout
diagnostic confirms received PCM. Speaker/AEC and a public wrapper playout API
are not established. Tests/processes have ended, the dedicated scheduled task
is removed, and WPR is no longer recording ([cleanup](results/cleanup.json)).

### Permissions controlled follow-up

The owner reported that two Windows permission dialogs had remained unapproved
during the first run. Their original titles were not captured, so the first
run does not establish the dialog permission state. After the owner confirmed
approving both, the same executable and same DLL were run again in the normal
and native-playout-off diagnostic modes. Read-only inspection found enabled
Private/Public Allow firewall rules for both app executables; the agent did
not change security settings.

[Follow-up evidence](results/permission-recheck.json) shows that normal mode
still receives audio RTP (203 then 406 packets) and video but 0 PCM samples, with
the same render initialization result 0x887c0030. The diagnostic again receives
238,080 then 195,360 nonzero-RMS PCM samples and has 0 off-window RMS. Both traces
have no loss and record/MF1, SDK capture attempts 0. Thus approving the dialogs
did not resolve the normal rendering failure. This does not establish the
original dialog type or rule out every possible permission interaction. The
old-binary exercise was not repeated in this two-run follow-up.

To regenerate the summary from privately retained inputs:

```sh
python3 upstream/wrapper/runtime/assess_permission.py <private-normal-and-diagnostic-dir> <cleanup.json> upstream/wrapper/runtime/results/permission-recheck.json
```

A later [normal playout experiment](../../playout/README.md) succeeds on the
compatible stereo speaker with public output selection after PeerConnection
creation. It uses this same submitted DLL; the default-route failure above
remains a distinct condition.
