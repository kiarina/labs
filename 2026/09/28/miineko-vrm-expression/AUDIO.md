# Audio-backed vowel playback

## Question and scope

Can the accepted five mouth shapes follow an actual audio file while preserving
the playback position through pause, seek, speed changes, stop and manual takeover?
This stage isolates that question using five individually synthesized vowels.
Their identities are known by construction; this is not speech recognition or
phoneme inference. Kyoko is a temporary test voice, not the character's voice.
The accepted VRM, geometry, materials and export metadata remain unchanged.

## Reproduce locally

Prepare the accepted model and Node dependencies described in [BASELINE.md](BASELINE.md).
Generate the fixture on macOS with the installed Kyoko voice and Python 3 stdlib:

```sh
python3 scripts/build_vowel_audio.py
AUDIO_RUN=vowel-audio-repeat python3 scripts/build_vowel_audio.py
mise run audio-motion-probe
```

The second generation is required by the repeatability check. Existing fixture
files in those two output directories are replaced; no VRM is written. A machine
without this system voice can use a previously generated WAV/manifest pair for
playback, or synthesize a separate comparison using `TEST_VOICE`. Voice and OS
updates can change the bytes. Preserve the fixture pair for exact comparisons;
do not treat identical synthesis on this machine as a cross-OS guarantee.

Serve the lab over loopback HTTP and open
`viewer.html?model=mouth-aa-aligned&motion=1&audio=1`. The audio option is selected
when ready, but playback requires pressing **音声と口を再生**. Volume, speed,
strength and position controls are available. Pause freezes both time and pose;
stop/end closes the mouth. Manual mouth edits and switching modes stop audio.
Hiding the page pauses playback. The silent and static modes work without the
audio files. Failed loading or a hash mismatch leaves those modes available.

Generated WAVs, manifests and captures stay in ignored `artifacts/`, alongside
this experiment's private character inputs. They are not published by this task.
Only code, methods and numerical evidence are tracked.

## Method

`build_vowel_audio.py` calls `say` separately for あー。/いー。/うー。/えー。/おー。
using Kyoko, rate 140, mono signed 16-bit PCM at 22,050 Hz. It records exact
commands, source hashes, text, OS version and trimming boundaries in the manifest.
The recorded clip is 3.897506 seconds, with 350 ms leading silence, 400 ms gaps
and 200 ms extra trailing silence. Trimming retains 30 ms margins around detected
energy. RMS windows are 220 samples, about 9.98 ms; the 90th percentile of active
RMS normalizes strength, followed by centered five-window smoothing. These
offline envelope choices are not a real-time microphone algorithm.

`audio_mouth.mjs` samples that envelope inside the known cue's interval. Other
vowels and silent gaps are zero. The existing normalizer enforces finite,
nonnegative weights totaling at most one. Default strength is 80%.
`HTMLAudioElement.currentTime` is the sole mouth clock, including after seeking
and playback-rate changes. The viewer verifies the WAV SHA-256 before decoding
the same bytes from a Blob URL, then checks duration against the manifest.
No extra animation timer tries to stay in sync with the audio clock.

## Observations — 2026-09-28

[results/audio-motion-evaluation.json](results/audio-motion-evaluation.json)
records the browser run. Two local syntheses produced identical WAV and manifest
bytes. The WAV hash is
`74b2fa288cf1cac4c81205b9122dc64a7ebdd65a4c50128222472e6bffc905a4`.
Node tests cover cue boundaries, invalid data, silence and media-clock controls.
Chrome checks all five cue peaks, actual playback to completion, blink overlap,
pause/resume, seek, 1.5× speed, stop, manual takeover, mode changes and rejection
of a mismatched audio hash. Automated playback is muted at the browser level.

The live run visited all five vowels over 238 sampled frames; weight total never
exceeded 0.8. Comparing the already-rendered weights with a subsequent reading
of `currentTime` produced a maximum weight difference of 0.060103. This compares
two slightly different sampling instants; it is neither zero-error evidence nor
a measurement of speaker/display latency. Front and side captures plus 1280,
600 and 390 px layouts were inspected. The in-app browser also reached the end
of the audio clip and returned to a closed mouth.

An initial test found that a pending `play()` promise could overwrite a manual
mouth edit. The completion/error handlers now respect manual takeover; the
browser regression exercises this transition. Existing silent-motion and static
expression checks pass. The accepted VRM hash remains the one in BASELINE.md.

## Next work and limits

The [continuous greeting preview](SPEECH.md) now tests one sentence using explicitly
authored approximate timing. Evaluate its artistic timing before extending the
method; automatic alignment remains open. RMS alone cannot distinguish vowels. Consonants, coarticulation,
natural expression timing, microphone/streaming input, physical output latency
and the final character voice remain unverified. This test does not certify
additional emotions, gaze, springs or every possible pose/weight combination.
