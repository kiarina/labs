# Physical human double-talk practicality check

This extension keeps the pinned engine, SDK and capture path from the parent lab.
It changes the near source to a real participant: **no synthetic near injection**.
The Windows camera-capable acquisition remains, but the available Windows setup
uses explicit synthetic video; this does not validate a physical camera.
Raw voice, decoded receiver PCM and listening WAV files stay ignored/local.
Only aggregate metrics, hashes and the participant's assessment enter Git.

## Protocol fixed before recording

The participant uses the normal microphone position and speaker, presses Start,
and follows the large on-screen cue. RAW record capture stays open throughout.
Application far-speech gain2, endpoint selection and OS levels stay fixed.
The sent profile is baseline; all four alternatives process the same input.

| Phase | Seconds | Participant |
|---|---:|---|
| quiet | 4 | silent |
| near-only | 10 | read the displayed sentence repeatedly |
| far warmup | 12 | silent |
| far-only | 6 | silent |
| double-talk | 16 | read the second sentence over speaker speech |
| quiet | 3 | silent |
| far-only | 6 | silent |
| near recovery | 8 | read the first sentence |
| quiet | 3 | silent |

Two WebRTC send gates run during/after DT. The receiver's decoded audio is tapped
into a local PCM file with per-chunk capture/time markers and format metadata.
It is never played back to the source microphone. Afterwards, six seconds of
received far audio exercise the owned speaker/reverse path. Recording runs until
all checks finish. Capture is not reopened at sender gate changes. Participant
can abort; an aborted run cannot establish practicality.

## Decision

A practical result requires all of the following:

- One record capture, all seven SDK recording counters0, RAW request/accepted/start1,
  MF capture0, clean shutdown active0/HRESULT0, transport and received-far checks pass.
- No raw/output clipping and no repeated capture gaps over100ms. Capture/frame
  counts must keep advancing during sender-off and sender-on periods.
- Far-only render-coherent reduction at least15dB on identifiable data. Weak
  raw/reference coherence is inconclusive, not an automatic pass.
- The participant listens to the **decoded receiver** DT segment and near-only/
  recovery comparisons: normal words remain intelligible, no repeated syllable
  loss or pumping, speaker echo is absent or slight enough for conversation.
  Record clarity (1–5), echo (none/slight/distracting), missing words and overall
  usability. Clarity>=4 and no repeated missing words/distracting echo are needed.

Real near speech has no independent clean reference in this setup. Do not apply
synthetic-near gain/correlation assertions or claim measured source separation.
DT cross-spectral echo estimates are diagnostics, and cannot by themselves prove
near retention. One participant/setup and a short run establish only a limited
practical result; other microphones, real camera, Bluetooth, long sessions and
other OS remain outside this check. If results are borderline, preserve failure
and run one fresh repeat rather than adjusting criteria after hearing it.

The physical live speaker is the near participant. Far speech is the existing
recorded shared fixture played through the speaker, rather than a second live
human conversation partner. The result must retain that distinction.

## Reproduce and analyze

Prepare and build as in `docs/windows-run.md`, with target
`lib/human_probe.dart`, `EXTERNAL_OUTPUT=baseline`, `EXTERNAL_FAR_GAIN=2`,
`AEC_RECORD_RAW=1`, and `EXTERNAL_EXIT=false`. Start is a participant UI action.
Collect current `aec_*.pcm`, `aec_result.json` and `human_received.pcm` into one
fresh ignored `build/human-trial-N` directory and rename the JSON to `report.json`.

```sh
uv run --with-requirements requirements-analysis.txt python tools/analyze_human.py \
  build/human-trial-1 results/human-trial-1.json
```

The tool creates local listening WAV files under that trial directory, using one
common gain for every clip. Do not normalize each clip independently. Receiver
clips are separate sender gates; their boundaries are edits, not evidence of
missing live words. Keep the participant assessment separate from DSP diagnostics.

## Observed result

**Limited practical acceptance: yes, for this short run and this setup.** The sent
profile was baseline AEC, not the unadopted synthetic-near improvement candidate.
The near participant reported decoded receiver clarity4–5/5, no missing words,
and no-to-slight echo. The first near-only and post-DT near clips both sounded
normal, with no reported word loss or pumping. This is participant listening,
not independent listening by a second person.

| Check | Observation |
|---|---|
| Record ownership | one RAW start, MF0, active0/HRESULT0 after disposal |
| WebRTC additional recording | all seven counters0, six protected peers |
| Far-only coherent reduction |20.61 /23.08dB, both intervals identifiable |
| Live DT | performed; spectral estimate is not identifiable enough for a clean-echo claim |
| Capture gaps |audio maximum20.976ms, video45.482ms |
| Raw/variant clipping |0 samples |
| Receiver |48k mono PCM,588960 samples, two send gates, tap drops0 |
| Received far playback |pass |
| Participant receiver assessment |clarity4–5, no missing words, echo none-to-slight |
| Participant near recovery |both clips sound normal |

See [objective diagnostics](results/human-trial-1.json),
[participant feedback](results/human-listening-1.json), and
[predeclared-criteria assessment](results/human-assessment-1.json).
No claim is made that a new DSP setting improved on baseline, that the DT metric
measures clean near gain, or that this validates long or remote conversations.

An additional **exploratory**, post-collection sender/receiver waveform comparison
failed a naive global correlation/projection-gain check; its original failure is
retained in `results/human-delivery-1-global-exploratory.json`. It is not a
predeclared practicality criterion. RTP reports show adaptive time scaling
(inserted/removed samples), so fixed sample alignment is inappropriate.
Whole-window RMS transfer was-.37/-.87dB; this differs from phase-sensitive
projection gain. The expanded [delivery diagnostics](results/human-delivery-1.json)
preserve both global and local-band comparisons and receiver time-scaling counters,
without claiming waveform identity or explaining all codec distortion. Packet
loss/concealment counters and repeated active-window energy loss are also retained.

All voice PCM and WAV files remain ignored/local. The completed executable and
trial-only scheduled tasks were stopped/deleted, SDK hashes remained unchanged,
and OS volume/effect settings were not modified.
