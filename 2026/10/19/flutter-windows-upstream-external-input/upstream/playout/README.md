# Normal Windows native speaker playback with external capture

**Normal native playback works on the measured EDIFIER M60 output, using the
submitted core #314/wrapper #158 DLL unchanged.** Continuous record acquisition
and synthetic camera frames stay active, and external-only trials have zero SDK
microphone capture attempts. A 660Hz remote-input pilot reaches the same render
endpoint, and the operator confirmed hearing both bursts. No native playout-off
diagnostic, mixer pull, new SDK patch or system audio-setting change is used.

The DLL remains `73b672f90beba282e04ae6dd9dbcb7b3af574d192977ae9224c382075dbcd740`.
It is the locally built submitted candidate, not an official released SDK.

## Required output selection

Use the existing public Flutter API **after creating the first media-enabled
PeerConnection and before SDP negotiation**. The lab creates both connections,
then selects the output:

```dart
final sender = await createPeerConnection(configuration);
final receiver = await createPeerConnection(configuration);
final outputs = await navigator.mediaDevices.enumerateDevices();
final speaker = outputs.firstWhere((d) =>
    d.kind == 'audiooutput' && d.label.contains('EDIFIER'));
await Helper.selectAudioOutput(speaker.deviceId);
// Add tracks and negotiate; leave normal native audio playout enabled.
```

Use the user's selected output ID in a product; the model-name match is a lab
fixture. Output selection is shared by the factory. The initial media-engine
reference sets Windows' default communications output. Selecting the speaker
before that initialization is overwritten. If all media connections are disposed
and the engine initializes again, reapply selection. Hot-plug and that complete
recreation sequence were not tested in this run.

This uses public `Helper.selectAudioOutput`, not source-matched private headers
for routing. The existing lab still has private-header diagnostic code compiled
in, but these successful trials do not invoke it. Core/wrapper source and DLL
are unchanged; only the probe app gains output selection and an optional pilot.

## Cause of the earlier initialization failure

The Windows console default is stereo 96kHz float32, while the communications
default is four-channel 48kHz float32 on this setup. The legacy ADM probes only
mono/stereo PCM16. No candidate is accepted on the four-channel endpoint, yet
InitPlayout calls Initialize with its last rejected candidate, mono192kHz PCM16.
The format probe independently returns 0x88890008 for those unsupported formats;
ETW records internal 0x887c0030 with HResultMapped 0x88890008 in the failing app.

The exact stereo 96kHz PCM16 format succeeds on the console/speaker endpoint.
Once selected after media-engine initialization, the same SDK initializes and
starts that two-channel96kHz render client. The first attempted pre-peer selection
remains a retained negative case; it selected EDIFIER early, then still rendered
to the communications endpoint and received 0 decoded PCM.

The source paths explaining the lifecycle are
[ConnectionContext::AddRefMediaEngine](https://github.com/webrtc-sdk/webrtc/blob/51c367e209f8f12b39bd8dd0ca70bf588f42cb48/pc/connection_context.cc),
[adm_helpers::Init](https://github.com/webrtc-sdk/webrtc/blob/51c367e209f8f12b39bd8dd0ca70bf588f42cb48/media/engine/adm_helpers.cc),
and the legacy AudioDeviceWindowsCore InitPlayout format loop. The candidate's
ordinary wrapper patch adds 176.4/192k rates but does not add four-channel support.

[format_probe.cc](format_probe.cc) checks both default roles with fresh clients,
WAVEFORMATEX/EXTENSIBLE PCM16 and exact engine mix formats without starting sound.
[Probe results](results/format-probe.json) also show that Windows' AUTOCONVERTPCM
flags can initialize 48k mono/stereo on the four-channel endpoint. Those flags
are a separate possible native fallback, not implemented or product-validated
here. [Microsoft documents the channel/rate conversion flags](https://learn.microsoft.com/en-us/windows/win32/coreaudio/audclnt-streamflags-xxx-constants).

## Results

Six separately traced processes use the same DLL. All have zero lost events and
buffers, capture caller stacks and unchanged endpoint volume/mute.

| Case | record/MF starts | SDK capture clients initialized | Normal render | Received PCM, two on windows |
| --- | ---: | ---: | --- | --- |
| pre-peer output selection, negative | 1 | 0 | rejected | 0 / 0 |
| public output selection after peers | 1 | 0 | stereo 96kHz, started | 238560 / 194880 |
| ordinary factory, positive capture control | 1 | 2 | stereo 96kHz, started | 238560 / 195360 |
| external-only track disable/enable | 1 | 0 | stereo 96kHz, started | 238560 / 195840 |
| external-only replaceTrack(null)/restore | 1 | 0 | stereo 96kHz, started | 238560 / 195840 |
| external-only remote pilot, audible | 1 | 0 | stereo 96kHz, started | 238080 / 195360 |

The ordinary-factory control has two distinct SDK capture clients initialized
and started during its process lifetime, on the same microphone endpoint as
record. This is not a claim that both SDK clients overlap in time. All
external-only cases have none. Source acquisition starts once and raw audio/video
advance through every phase, including off windows. Stop windows have zero
received PCM RMS after settling; both resumption windows have nonzero PCM and
video. Track/replace transitions each complete two cycles.

The pilot replaces outgoing test-track samples with a known 660Hz tone while
record continues, so the captured speaker signal cannot feed back. Other trials
use actual record PCM. The pilot requests receiver volume 0.25; this is not a
calibrated gain or loudness measurement. [loopback_probe.cc](loopback_probe.cc)
records only numeric RMS and 660Hz projection from the render endpoint, in a
separate observer process. It opens no microphone and stores no PCM/WAV. Its
endpoint hash matches both the public selected device ID and the successful
native render endpoint. Settled on windows have median pilot amplitude about 0.0799;
off windows have 0. The [operator report](results/human.json) confirms both bursts
were audible. The first orchestration did not retain an observer exit code;
that null is preserved in build.json. The complete 45-second metric sequence,
empty observer error log and process cleanup are separately retained.

[summary.json](results/summary.json) contains phase/ETW/signal results and private
trace input hashes. [build.json](results/build.json) identifies the app source,
runner and Dart AOT assets; the runner itself did not change when Dart changed.
The previous release/source are backed up locally.
[cleanup.json](results/cleanup.json) confirms no app/observer/scheduled task remains
and WPR has stopped.

## Reproduce and verify

Use a fresh/private copy of the parent lab with the submitted candidate SDK and
its matching headers/import library. Copy [main.dart](main.dart) over
`app/lib/main.dart`, preserve the previous release, and build Windows normally.
The input pins/lockfile remain those of the parent lab. No DLL rebuild is needed.
Build each standalone C++ probe from a VS2022 x64 developer prompt:

```bat
cl /EHsc /std:c++17 format_probe.cc ole32.lib uuid.lib
cl /O2 /EHsc /std:c++17 loopback_probe.cc ole32.lib advapi32.lib
```

In an elevated interactive Windows session, with Python and xperf on PATH:

```powershell
./upstream/playout/run.ps1 -LabRoot '<lab-copy>' -OutputDirectory '<fresh-output>'
# Audible pilot with render-endpoint observation:
./upstream/playout/run.ps1 -LabRoot '<lab-copy>' -OutputDirectory '<fresh-pilot-output>' `
  -Pilot -RequestedReceiverVolume 0.25 -LoopbackProbe '<loopback_probe.exe>'
```

`run.ps1` is the parameterized version of the measured commands. Other variants
are `track-gates`, `replace-gates`, and `-ExternalOnly $false` for the positive
control. Never cancel another WPR recording. Private inputs retain normalized
ETW/app results, SDK/policy manifests and volume-before/after snapshots. Use
`assess.py <private-input-folder> <loopback.jsonl> results/summary.json` to aggregate.
Run `python3 upstream/playout/verify.py` or the lab's `mise run` to validate saved
evidence and six corrupted-evidence rejection cases without device access.

The four-channel communications-default path is still unsupported without an
explicit compatible output choice. AEC/reverse-reference quality, live human
double-talk, physical Windows camera, other output devices, hot-plug, long runs
and other OS remain unvalidated. Synthetic camera frames are not a physical
camera result. These results do not make the complete product integration ready.
