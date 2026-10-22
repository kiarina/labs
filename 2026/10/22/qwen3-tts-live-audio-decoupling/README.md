# Decoupling live text arrival from Qwen3-TTS audio generation

**Direct text-PAD substitution is not usable in these tests.** It reduces input waiting, but changes what is spoken, produces repetition, and can prevent normal termination. A conservative alternative—finalizing short received text spans and reusing a prepared full-reference state—retains much better reading and speaker metrics. With a one-second initial playout hold, it has no measured queue starvation in the eight ordinary/call-cadence test cases. This is a lab result, not a production integration or proof of perceptual naturalness.

This follows [explicit reference/target boundaries](../qwen3-tts-explicit-boundary/README.md). The full reference remains unchanged. The experiment was motivated by both Japanese and English calls producing intermittent audio during text arrival, then steady audio after input completion.

## What was tested

44 measured utterance conditions plus six excluded warmups, on a **MacBook Pro M1 Max 64GB** in an isolated process. No production server changes or physical speaker playback. Output timing excludes reference preparation, as preparation can happen before the first text.

- Qwen3-TTS Base 1.7B bf16, model revision `a6eb4f68e4b056f1215157bb696209bc82a6db48`.
- Python3.12.10, mlx0.32.4, mlx-audio0.6.1, transformers5.20.2, NumPy2.5.4; all dependencies are frozen in `uv.lock`.
- One full 256283-sample/24kHz reference (10.678s), SHA256 `c03e2da1cf1877fc829168840d894fb846716c69d80d4f00ae4cdaafea96a5c0`. Private reference and transcript are not distributed.
- Two public synthetic scripts in `bench.py`, one Japanese and one English. Nominal input intervals:130ms/Japanese character and60ms/English character. Actual arrival/done times are retained; relative sleeps include scheduling jitter.
- Seeds42/43/44 for the main strict/PAD12/segmentation comparison. PAD4 and unrestricted PAD were screened with seed42 only; counts are explicit in the metrics.
- Same fresh reference-text EOS + reference-codec EOS + role/language/speaker prefix, full decoder priming, temperature0.9, top-k50, top-p1, repetition penalty1.05, four codec frames/PCM chunk (normally320ms), cap500 frames per generation.
- Fixed Whisper large-v3-turbo reading diagnostics and independent ECAPA speaker cosine. ASR is an imperfect proxy; CER can exceed100% for repeated/unrelated speech. ECAPA on a failed output does not make that output acceptable.

### Candidate policies

| Mode | Input starvation behavior |
| --- | --- |
| `strict` | Each codec step waits for the next committed text token until text closes. |
| `pad4` | Substitute special text PAD for at most four consecutive missing-token steps. |
| `pad12` | Same, at most twelve consecutive steps. |
| `pad_free` | Same, no per-gap limit; overall500-frame cap remains. |
| `segments` | Close short received text spans independently; prepare the same reference again per span. |
| `segments_cached` | Same spans, but fork an immutable prepared talker/decoder state per span. |

PAD never advances the text cursor. All real text and target EOS must be fed before acoustic EOS is allowed. While input remains open, PAD generation is paced to at most320ms of audio lead over wall time. This is **experimental conditioning not established by model training**. A low gap metric alone is not a success criterion.

The span policy uses punctuation after at least8 Japanese characters/14 English characters; otherwise24 Japanese characters or six English words; the last tail closes with input. Available punctuation is preferred, so a full-input control can use different spans from incremental input. Each span has its own EOS and independent generation state. This is **not one continuous model generation**. Text reception and audio output can still overlap through a queue, and a persistent transport is possible, but no new transport/product implementation is included here.

## Main results

Medians over three seeds, ordinary incremental schedules. `Gap` is cumulative PCM supply shortage with playout starting immediately at first PCM, excluding gaps below20ms and the final silence after completion. It does not measure natural acoustic pauses within the audio.

| Language / mode | First PCM | Gap | Mean reading error | Mean ECAPA |
| --- | ---: | ---: | ---: | ---: |
| Japanese strict | 1.910s | 2.821s | CER3.51% | 0.751 |
| Japanese segments | 1.971s | 0.227s | CER3.51% | 0.764 |
| Japanese segments_cached | 1.963s | 0s | CER3.51% | 0.764 |
| English strict | 0.702s | 4.552s | CER1.92% / WER2.90% | 0.684 |
| English segments | 1.836s | 1.077s | CER0.38% / WER1.45% | 0.739 |
| English segments_cached | 1.828s | 0.618s | CER0.38% / WER1.45% | 0.739 |

Japanese ASR differences in seeds43/44 are the opening interjection, also present in the strict control; the remainder is recognized as the target. Speaker metrics did not decrease on average in this small paired comparison. A human has not rated similarity, prosody, or span joins.

### PAD failures are retained

- Japanese PAD4 seed42: first PCM0.438s, but gap increased to3.350s and CER15.79%.
- Japanese PAD12: CER71.05% even in the only normally terminating seed; the other two reached the40s audio cap.
- Japanese unrestricted PAD seed42 and **all five incremental English PAD trials** reached the40s cap, with unrelated/repeated speech. Some had gap0; this was not valid target playback.
- In total8/44 measured conditions hit the declared cap. All resulting partial audio and traces remain locally available; none were silently dropped from aggregates.
- Full-input strict/PAD-free controls had identical PCM hashes in both languages. The failures arise when the starvation behavior is exercised, not just from changing the generator implementation.

## Continuity-first playout

During the experiment, the owner clarified that a somewhat later onset is preferable to intermittent speech. Recorded arrival arrays were replayed with0/300/600/800/1000/1200/1500/2000ms initial holds; **the waveform is unchanged** and no new favorable generation is selected per policy.

For `segments_cached` plus a **one-second initial hold**:

| Schedule | Start from first text | Cumulative queue starvation |
| --- | ---: | ---: |
| Japanese ordinary, three-seed median | 2.963s | 0s in3/3 |
| English ordinary, three-seed median | 2.828s | 0s in3/3 |
| Japanese real-call cadence replay, seed42 | 2.513s | 0s |
| English real-call cadence replay, seed42 | 2.399s | 0s |

The cadence replay maps cumulative character fractions from real-call numeric logs onto the synthetic scripts, retaining append/done times (`schedules.json`). It is not the original private transcript or a live GPT call. An800ms hold removed starvation from all six ordinary runs but left78ms in the English cadence replay; one second covered all eight cases. The strict policy still had substantial starvation with the same one-second hold.

**Adverse case:** deliberately stopping the producer for two seconds at two thirds of the script still leaves0.791s Japanese/1.249s English starvation with the selected policy. This is not a guarantee of gap-free speech under arbitrary stalls. A longer hold can cover more measured deficits at the cost of onset latency.

## State reuse and validity checks

- Eight cached/uncached PCM parity pairs: full-input seed42 for both languages and streamed seeds42/43/44 for both languages. All hashes match for corresponding span policies.
- All measured segment runs complete every character span and terminate normally. The whole-input token totals in their rows are bookkeeping, not the sum of independently tokenized span counts; span boundaries can alter BPE tokenization.
- All waveform values are finite. Failed PAD runs can have large peaks and irrelevant speech; do not use these as listening candidates for a product.
- `audit.py` checks reference identity, coverage/termination, parity, the eight one-second playout cases, and absence of raw ASR hypotheses from public metrics.

## Reproduce

Apple Silicon is required. Use a supplied24kHz mono reference and its accurate transcript. This lab does not modify installed mlx-audio or import another lab/kiapi at runtime.

```sh
uv sync --frozen
export REFERENCE_WAV=/path/to/reference.wav
export REFERENCE_TRANSCRIPT=/path/to/transcript.txt
uv run --frozen bench.py --reference "$REFERENCE_WAV" --transcript-file "$REFERENCE_TRANSCRIPT" --output output-screen --controls
uv run --frozen bench.py --reference "$REFERENCE_WAV" --transcript-file "$REFERENCE_TRANSCRIPT" --output output-confirm --modes strict pad12 segments --seeds 43 44
uv run --frozen bench.py --reference "$REFERENCE_WAV" --transcript-file "$REFERENCE_TRANSCRIPT" --output output-cache --modes segments segments_cached --seeds 42 --schedules full chars
uv run --frozen bench.py --reference "$REFERENCE_WAV" --transcript-file "$REFERENCE_TRANSCRIPT" --output output-cache-confirm --modes segments_cached --seeds 43 44
uv run --frozen bench.py --reference "$REFERENCE_WAV" --transcript-file "$REFERENCE_TRANSCRIPT" --output output-pause --modes strict segments_cached --seeds 42 --schedules pause
uv run --frozen bench.py --reference "$REFERENCE_WAV" --transcript-file "$REFERENCE_TRANSCRIPT" --output output-recorded --modes strict segments_cached --seeds 42 --schedules recorded
```

For each output directory, run `evaluate.py --output ... --reference "$REFERENCE_WAV" --reference-transcript "$REFERENCE_TRANSCRIPT" --asr`. It requires ffmpeg; `--reuse <evaluation.json>` reuses ASR hypotheses only for identical resampled PCM hashes. ECAPA and ASR model hashes/revisions are fixed in `evaluate.py`. Raw hypotheses stay in ignored outputs.

```sh
uv run --frozen publish.py output-screen output-confirm output-cache output-cache-confirm output-pause output-recorded
uv run --frozen replay.py output-screen output-confirm output-cache output-cache-confirm output-pause output-recorded --hold 1 --write-audio
uv run --frozen audit.py
```

`replay.py` creates PCM16 listening WAVs for seed42 including the initial text-to-audio silence and measured gaps. Strict examples have no added hold; cached-span examples use the requested hold. It does not stretch, crossfade, denoise, or otherwise alter generated speech. Reference/clone audio and raw traces are ignored and are not public research assets.

Public records: [all measurements](results/measurements.json), [three-seed summaries](results/summary.json), [playout policies](results/playout.json). Dependencies intentionally preserve the predecessor's frozen stack for comparison; this is not a claim that it is the newest package stack.

## Scope and next decision

The recommendation for further product evaluation is **cached short-span generation plus a one-second initial hold**, reflecting the continuity-first preference. Direct PAD-on-starvation is rejected for this implementation. Short-span generation changes prosodic boundaries, and neither human listening nor long multilingual conversations, actual network/device playout, interruption integration, or production-server hardware timing were validated in this lab. Do not treat these M1 measurements as production M4 call latency.

Provenance: preparation/text helpers adapted from the preceding explicit-boundary lab; immutable state-copy handling adapted from kiapi's prepared live generation helpers. All copies are local to this lab. Segmentation/decoupling/replay harnesses are experimental code owned here.
