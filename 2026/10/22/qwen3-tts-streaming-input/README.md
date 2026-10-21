# Qwen3-TTS streaming text input and audio output on Apple Silicon

## Purpose

Run the unmodified [keless fork](https://github.com/keless/Qwen3-TTS-streaming-input) on Apple Silicon before considering an MLX port and kiapi integration.

Questions: Does audio arrive before end-of-input? What are model-load time, time to first PCM, generation/audio ratio, and simulated playback underruns? Does unspaced Japanese commit incrementally? Can generation resume after input starvation?

Method: a timestamped producer supplies fragments while the stock API yields PCM. Measure English words, Japanese character deltas, Japanese phrase fragments with explicit whitespace, and a delayed producer. Record all inputs, seeds, dependency versions, source/model revisions, chunk times and sample counts. Run sequentially without physical playback; infer playback gaps from arrival time and audio duration, separately from device latency. Keep model load outside generation timing. No upstream code changes.

## Results (2026-10-22)

**Streaming text in and PCM out works, including pause/resume without changing
concatenated PCM. The stock Japanese boundary policy is not ready for direct
LLM-token input.** Unspaced Japanese waits for close; inserting phrase spaces
allows early output but changes the synthesized speech, with diagnostic ASR
errors in both tested speakers. Human listening is still needed before calling
these pronunciations correct or rating the voice/prosody.

Main run: Mac Studio, Apple M4 Max, 128 GB unified memory, macOS 27.0.1,
Python 3.12.11, PyTorch 2.14.1 / MPS float32 / eager, CustomVoice 1.7B, Vivian.
Exact package versions and model/source revisions are in
[environment.json](results/environment.json) and the lockfiles. No concurrent
model inference was observed at start; ordinary desktop applications remained
open. ASR ran after synthesis, not concurrently. These are small-probe results,
not guaranteed latency under production load.

Second pass (warm model/process):

| Input | First PCM from start | Input closes | Generate / audio | RTF | Predicted gaps, immediate playback |
|---|---:|---:|---:|---:|---:|
| English, complete upfront | 0.499 s | 0.000 s | 5.24 / 6.29 s | 0.832 | 0 |
| English, words every 50 ms | 0.644 s | 0.889 s | 5.37 / 6.29 s | 0.853 | 0 |
| Japanese, complete upfront | 0.497 s | 0.000 s | 7.76 / 9.02 s | 0.861 | 0 |
| Japanese, characters every 80 ms | 4.511 s | 3.849 s | 11.78 / 9.02 s | 1.306 | 0 |
| Japanese, spaced phrases every 600 ms | 1.708 s | 3.028 s | 8.74 / 8.21 s | 1.064 | 0.285 s |
| English, forced 3-second input pause | 0.500 s | 3.510 s | 8.25 / 6.29 s | 1.311 | 2.855 s |
| Japanese spaced phrases, forced pause | 0.512 s | 3.513 s | 10.12 / 8.21 s | 1.232 | 3.022 s |

The first invocation in the process had first PCM at 6.274 s and RTF 1.930;
model load itself was 0.967 s, excluding downloads/imports. Warm controls reached
about 1.16–1.20 times real-time throughput. Input-bound RTF includes producer
waiting and must not be interpreted as pure compute speed.

For spaced Japanese, one second of simulated audio prebuffer removes all
predicted gaps in both trials, but shifts playback start from 1.708 to 2.356 s
in trial 1. The stock 0.5-second prebuffer does not help here because the first
chunk already contains about 0.617 seconds. See
[all timings](results/table.md), [arrival/prebuffer tradeoffs](results/playback-tradeoffs.json),
and per-run JSON event/frame timelines in `results/`. All 14 runs completed
without errors, non-finite samples, safety caps or producer gate timeouts.

### Pause/resume and output parity

With seed 0, the following pairs' concatenated float32 PCM were exactly equal
(sample count and every sample), despite different arrival schedules:

- English upfront vs word input, and word input vs the 3-second forced pause.
- Japanese upfront vs character input (both only commit the unspaced text at close).
- Japanese spaced-phrase input vs the 3-second forced pause.

See [waveform parity](results/waveform-parity.json). This supports keeping the
same causal generation state across a short input stall in these cases; it
does not establish general quality or long-pause/timeout behavior. Waiting
preserves synthesis state but cannot create audio while input is unavailable:
the roughly 3-second playback gaps in the forced-pause cases remain real costs.

### Japanese transcription check

[Whisper results](results/transcripts.json), fixed large-v3-turbo revision,
temperature 0, contain the complete Japanese input for upfront/character cases
apart from punctuation. With explicit spaces, `少し` was transcribed as
`エツキッシー` in both trials. That same transcript appears after the forced pause.
English results match the intended words apart from case/punctuation.

We additionally ran the same stock API with `Ono_Anna`, the native Japanese
speaker listed in the [official model card](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice).
One run each of Japanese upfront, spaced phrases and forced pause is saved in
`results-ono-anna/`. The spaced variants again changed the ASR result: `少し` →
`今年`, `駅前` → `秋前`; the upfront control retained the intended words, with
an extra initial breath-like transcription. This argues against blaming only
Vivian's language profile. It does not prove an acoustic error or establish the
root cause: ASR is an imperfect diagnostic and human audition is outstanding.

The input policy strips incoming whitespace and adds a leading space to every
committed word/phrase after the first. Japanese phrase spaces therefore affect
tokenization/conditioning. Replacing the buffer alone with a punctuation flush
while retaining this embedding policy should not be assumed to preserve speech.

### Failed or excluded attempt

The initial attempt on an Apple M1 Max, 64 GB, was interrupted after discovering
another long-running GPU inference workload. One completed English control had
first PCM 31.737 s, generation 87.096 s, audio 6.295 s, RTF 13.836. It is retained
in `results-m1-contended/` solely as an excluded observation, not a hardware
comparison. The next in-progress trial was interrupted without complete output.
The main run was then moved to an isolated temporary environment on the M4 Max.
No live service or other task's processes were stopped.

## Decision and next experiment

The causal input/output mechanism is a useful reference for an MLX prototype.
Direct kiapi integration is not yet justified by this small stock run. Before
using the current voice-clone endpoint, the next experiment needs to:

1. Commit Japanese text incrementally without inserting model-visible spaces,
   with explicit tokenization/boundary tests, then compare readings and prosody
   against full-input controls using native Japanese listening and ASR.
2. Port the live causal-state/producer pause logic into an isolated MLX lab,
   starting with float32 parity fixtures rather than assuming current MLX
   full-input generation can accept more text unchanged.
3. Extend and verify Base voice cloning separately; this fork's working live
   wrapper is CustomVoice-only. Preserve the previous lab's sampling and onset
   corrections when evaluating the clone path.
4. Measure realistic LLM fragment schedules, first intelligible speech,
   buffering, cancellation, backpressure and pauses exceeding ten seconds.
   Only then choose a kiapi session/transport contract and production rollout.

No mlx-audio or kiapi source was changed in this experiment.

## Implementation scope

The pinned fork exposes `LiveTextSource.push(fragment)` / `close()` and
`stream_generate_custom_voice_live_text()`. The wrapper retains the talker's
causal KV cache while appending text embeddings. If it catches up to the text,
it waits for more input without calling the model. After confirmed end-of-text,
it supplies the trained end/pad conditioning so the model can finish speaking.
The source also treats ten seconds without a new fragment as a tentative end;
that is a protocol risk for long upstream pauses, not a confirmed user close.

This live-text wrapper accepts a single CustomVoice sample, not a Base model's
voice-clone prompt. The fork's `stream_generate_voice_clone(text=...)` still
takes a complete string; `non_streaming_mode=False` in that API alone does not
mean that an application can append new text after generation starts.

`LiveTextSource` commits through the last whitespace and splits it into words.
Japanese punctuation alone does not commit. Our `ja_phrases_space` case supplies
explicit whitespace between phrases; this changes model tokenization, rather
than demonstrating support for unchanged Japanese token deltas.

The upstream example uses MPS/float32/eager and fast codebook generation on Macs.
The HTTP server uses bfloat16 instead. This lab starts with the example's
float32 configuration. CUDA graphs, flash attention and CUDA-specific compile
speedups are not available in this run. The HTTP server plays on its own host;
this lab measures the Python PCM generator, not network transport or speakers.

Related prior experiment:
[Japanese zero-shot TTS comparison](../../20/japanese-zero-shot-tts-compare/README.md).
Its MLX timings use Base voice cloning and different precision/decoding, so they
are context for a possible next experiment, not a controlled speed comparison.

## Run and metrics

Requires an Apple Silicon Mac with sufficient free unified memory, uv, and
network access for the first download (CustomVoice weights and codec: about
4.2 GB). The committed `uv.lock` fixes the dependency graph; the qwen-tts git
revision and model revision are also fixed. No global packages are installed.
The upstream SoX warning is harmless for this PCM generation path; no external
SoX binary was installed. Flash attention is absent on this platform.

```sh
mise -C 2026/10/22/qwen3-tts-streaming-input run
# Alternatively, from this lab:
uv run --frozen bench.py
# Sequential optional diagnostic ASR, after generation finishes:
(cd asr && uv run --frozen transcribe.py)
uv run --frozen summarize.py
uv run --frozen replay.py ja_phrases_space-1 ja_starvation-1
```

- MPS, float32, eager attention, fast codebook enabled, seed 0, speaker Vivian.
  These follow `examples/live_text_to_speakers.py`. API defaults include emission
  every 8 frames, window 80, overlap 0, no two-phase first chunk. `max_frames=1000`
  is the sole safety-cap change to generation defaults. It was not reached.
- Each of the seven cases runs twice, in a single model process, sequentially.
  Only the first generation is the first invocation in that process. Two runs
  are a small functional/performance probe, not a statistical capacity study.
- `en_all` / `ja_all`: supply complete text immediately then close, through the
  same live API. These are controls, not the official offline `generate` API.
- `en_words`: one word plus whitespace every 50 ms.
- `ja_chars`: one character every 80 ms, with no inserted whitespace.
- `ja_phrases_space`: five Japanese phrases, each with a trailing space,
  every 600 ms. Full texts are in `bench.py` and `results/environment.json`.
- `en_starvation` / `ja_starvation`: supply initial text, wait for first PCM,
  then wait 3 seconds before supplying the remainder and closing. Gate timeout
  is 30 seconds. This forces a genuine input-source pause; it is not an LLM test.
- First PCM is measured from producer/generator start, including scheduled
  first-input delay. It is not a measurement of first intelligible speech or
  speaker output. Model download, Python imports and model load are excluded.
- RTF = wall-clock generation time / concatenated audio duration. It includes
  input wait time, so an input-bound case's RTF does not measure compute alone.
- Gap: ideal FIFO speaker starts at first chunk arrival and consumes samples
  at the sample rate. Count how much subsequent arrivals miss its deadline.
  This measures neither real audio-device jitter nor silences inside the PCM.
  The 0.5-second prebuffer cannot help if the first chunk is already longer
  than 0.5 seconds (here about 0.617 seconds); both gap columns then coincide.
- WAVs are concatenated float32 PCM. `replay.py` additionally renders the arrival
  timeline with leading startup silence and predicted underrun silence for
  audition; it is a simulation of playback, not a recording from speakers.
- ASR uses a separate locked environment and fixed Whisper model revision, at
  temperature 0, solely to flag missing/substituted words. It does not rate
  voice resemblance, naturalness, prosody, or audible chunk boundaries.

Large generated audio remains in ignored `output/`. Compact JSON timelines,
source/model/environment identifiers and transcripts are kept in `results/`.


Supplementary native-speaker reproduction (run after the main benchmark):

```sh
uv run --frozen bench.py --speaker Ono_Anna --cases ja_all ja_phrases_space ja_starvation --trials 1 --output output-ono-anna
(cd asr && uv run --frozen transcribe.py --output ../output-ono-anna)
uv run --frozen summarize.py output-ono-anna --destination results-ono-anna
```
