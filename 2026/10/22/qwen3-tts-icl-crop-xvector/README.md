# Qwen3-TTS live cloning: cropped ICL reference with full-reference speaker embedding

## Question

Causal ICL overlays "reference transcript + target text" on the reference codec rows, so live text cannot start generating until the target covers the rows the reference transcript leaves uncovered. With the 10.678-second reference used in [the same-reference x-vector comparison](../qwen3-tts-live-xvector-compare/README.md) this is 105 target tokens, and short replies only start after `text.done`. Speaker embedding alone starts early but scored lower on an independent speaker encoder (0.654 vs 0.747).

The Base model's ICL prompt already contains an x-vector next to the reference codes. This lab keeps that x-vector from the **complete** reference and shortens only the **ICL segment** (reference codes, decoder priming and its transcript). Questions:

1. How does the startup requirement (target tokens) fall as the ICL segment shrinks?
2. Where between full ICL (0.75) and x-vector only (0.65) does independent speaker similarity land for each segment length?
3. Does reading (ASR CER) or termination break for short segments?
4. Does the full-reference x-vector matter once ICL is short (ablation: same short segment, x-vector from the segment)?
5. Does segment content matter at similar length (an emotional final clause versus neutral sentences)?

This is a different lever from the [PAD prefill comparison](../qwen3-tts-pad-prefill-compare/README.md), which keeps the whole reference in ICL and changes the text layout. Model weights and layout are unchanged here; only which audio/transcript is used as ICL changes.

## Conditions

Segments are cut inside measured pauses of the reference (20 ms RMS < .006 for ≥ 160 ms) and cross-checked against fixed Whisper large-v3-turbo word timestamps, so each segment's transcript is an exact slice of the reference transcript.

| mode | ICL segment | ICL transcript | x-vector from |
|---|---|---|---|
| `icl` | complete 10.68 s | all 3 sentences | complete |
| `crop-tail23` | 3.4 s – end (7.28 s) | sentences 2–3 | complete |
| `crop-tail3` | 6.6 s – end (4.08 s) | sentence 3 | complete |
| `crop-head1` | 0 – 3.2 s (3.20 s) | sentence 1 | complete |
| `crop-mid2` | 3.3 – 5.9 s (2.60 s) | sentence 2 | complete |
| `crop-clause` | 8.5 s – end (2.18 s) | last clause of sentence 3 | complete |
| `crop-clause-spkcrop` | same as `crop-clause` | same | the segment (ablation) |
| `xvector` | none | none | complete |

Everything else follows the predecessor lab: nonquantized Base 1.7B bf16 at a fixed revision, Japanese, causal live-text adapter that never inserts EOS/PAD while input is open, tokenizer pre-token commit rule, 4-frame PCM chunks, sampling 0.9 / top_k 50 / top_p 1 / repetition penalty 1.05. Same short (45 chars) and long (125 chars) texts. Main run: one Unicode character every 80 ms, seeds 42/43/44, plus a seed 42 full-input control per mode. Secondary: 40 ms/character, seed 42. Mode order rotates per seed. One seed 0 full-input warmup per mode is recorded and excluded.

Measurements and their limits are the same as the predecessor: first PCM, simulated first voiced playout, stall sum without extra buffer, independent ECAPA-TDNN cosine against the complete reference, fixed-Whisper CER, EOS/finite/clipping. Speaker cosine and CER are diagnostics; they do not establish perceived similarity or Japanese naturalness. `listen.py` builds a side-by-side page for human listening (not blinded).

The reference and its transcript are private inputs (ignored `.input/`); `bench.py` asserts the 60-character transcript the crop slices were written for. Generated clone audio is ignored and not published.

## Run

```sh
export REFERENCE_WAV=/path/to/reference.wav
export REFERENCE_TRANSCRIPT_FILE=/path/to/transcript.txt
mise run run
uv run python summarize.py --output output   # per-mode table, writes summary.json
uv run python -m http.server 8791   # then open output/listen.html
```

Crop times in `bench.py` are specific to the private reference; another reference needs its own pause-aligned `CROPS`.

## Results (2026-10-22)

**ICL の区間を短くしても、声の似方と開始の速さのよい折り合いは見つからなかった。** 2〜4 秒まで短くすると、独立 encoder の類似度は話者埋め込みのみとほぼ同じ所まで下がり（0.67〜0.69 対 0.65、全体の ICL は 0.75）、それでも 23 トークン以上待つ。短い返事（今回の短文は全部で 25 トークン）では、どの区間でも入力完了の後にしか始まらない。参照全体の話者埋め込みは効いていた（同じ区間で埋め込みも区間から取ると下がる）。

Apple M4 Max 128GB, macOS 27.0.1, Python 3.12.11, MLX 0.32.4, mlx-audio 0.6.1, transformers 5.20.2. The kiapi service was running but idle (queue 0, no model loaded); not an exclusive-GPU measurement. A watcher sampled every 20 s for other bench/evaluate processes during the run and found none. 96 generations (8 warmups excluded) all ended with EOS, finite PCM, no clipped samples, no errors.

### Startup and stalls (80 ms/character, seeds 42/43/44, median)

"First voice" is the simulated first voiced playout from input start (first 10 ms RMS > .003, honoring chunk arrivals; no device latency). "Stall" is the summed playback gap if playback starts at first PCM with no extra buffer. Input finished at about 3.9 s (short, 45 chars) and 10.9 s (long, 125 chars).

| mode | ICL / wait tokens | short: first voice | short: stall | long: first voice | long: stall | long: started before text.done |
|---|---:|---:|---:|---:|---:|---:|
| `icl` | 10.68 s / 105 | 4.92 s | 0 | 11.99 s | 0 | 0/3 |
| `crop-tail23` | 7.28 s / 75 | 5.03 s | 0 | 11.48 s | 0 | 0/3 |
| `crop-tail3` | 4.08 s / 43 | 4.87 s | 0 | 7.86 s | 1.41 s | 3/3 |
| `crop-head1` | 3.20 s / 28 | 4.26 s | 0 | 4.98 s | 2.57 s | 3/3 |
| `crop-mid2` | 2.60 s / 26 | 4.56 s | 0 | 4.93 s | 3.02 s | 3/3 |
| `crop-clause` | 2.18 s / 23 | 4.59 s | 0 | 5.26 s | 2.80 s | 3/3 |
| `crop-clause-spkcrop` | 2.18 s / 23 | 4.52 s | 0 | 5.07 s | 2.82 s | 3/3 |
| `xvector` | none / 1 | 2.27 s | 1.53 s | 2.79 s | 2.95 s | 3/3 (short too) |

- The requirement falls roughly with segment length (≈ 10 tokens per second of reference here), because the codec runs at 12.5 frames/s while a Japanese transcript covers far fewer tokens per second. Even the 2.18 s clause needs 23 tokens, about 40 characters of Japanese text in these prompts.
- The short text has 25 tokens in total, and the pre-token commit rule holds the last piece until `text.done`, so no crop started before input finished on it. Crops differ from full ICL by well under a second there.
- On the long text, crops of ≤ 3.2 s start about 7 s earlier than full ICL, but without a buffer they stall about as much as x-vector only (2.6–3.0 s). Early start and continuous playback are still separate problems.

40 ms/character, seed 42 (one run each; audio identical to the 80 ms seed 42 runs, see below) showed the same ordering: long-text first voice was 6.96 s for `icl`, 2.78–3.35 s for crops ≤ 3.2 s and 1.65 s for `xvector`; on the short text every mode except `xvector` waited for `text.done`. See [40 ms results](results/40ms/summary.json).

### Speaker similarity (independent ECAPA-TDNN against the complete reference)

Six 80 ms/character outputs per mode (2 texts × 3 seeds).

| mode | mean | range |
|---|---:|---:|
| `icl` (10.68 s) | 0.747 | 0.716–0.771 |
| `crop-tail23` (7.28 s) | 0.686 | 0.620–0.756 |
| `crop-tail3` (4.08 s) | 0.676 | 0.649–0.724 |
| `crop-clause` (2.18 s) | 0.675 | 0.595–0.708 |
| `crop-mid2` (2.60 s) | 0.672 | 0.648–0.727 |
| `crop-head1` (3.20 s) | 0.642 | 0.485–0.686 |
| `xvector` (none) | 0.654 | 0.621–0.693 |
| `crop-clause-spkcrop` (2.18 s, x-vector from segment) | 0.619 | 0.350–0.714 |

- Only `icl` stays clearly above x-vector only. Segments of 2–4 s land 0.01–0.03 above it on average with overlapping ranges; with three seeds per text these are not distinguishable from x-vector only. `crop-tail23` reached 0.726 on the long text but 0.647 on the short text.
- Similarity is not monotonic in length: the 3.2 s first sentence scored lowest of the full-x-vector crops, and the 2.18 s emotional final clause scored as high as the 4.08 s full final sentence. Segment content seems to matter as much as length; this is an interpretation from one reference.
- Taking the x-vector from the 2.18 s segment instead of the complete reference lowered the mean (0.675 → 0.619) and produced the lowest single score in the lab (0.350, short text, seed 42). Keeping the complete-reference x-vector is worth it whenever the ICL segment is short.
- The 40 ms/character outputs are byte-identical (PCM SHA-256) to the 80 ms seed 42 outputs in all 16 cases. The adapter waits instead of stepping when text is missing, so input speed changed only arrival times, not audio. The 40 ms run therefore adds timing evidence but no independent quality samples.

### Reading

All character-input outputs had normalized Whisper CER 0 on the short text and 0–2.61 % on the long text; the non-zero cases are the same 「おいしい」/「美味しい」 spelling difference seen in the predecessor plus one 2.61 % case for `crop-head1`. No repeated or dropped passages were found by ASR. This does not establish natural Japanese prosody.

### Conclusion and limits

For this reference, shortening the ICL segment is not a usable middle ground: it gives up most of the measured similarity advantage of full ICL before the startup requirement falls low enough to matter for short replies. A lever that keeps the complete reference in ICL while removing the text requirement (for example the PAD-prefill layouts) or a different startup policy is needed instead. If cropping is used at all, keep the x-vector from the complete reference.

Not checked: human listening (the page `output/listen.html` is generated for that; no ratings assigned), other references or speakers, segments shorter than 2.18 s, crops not aligned to pauses, quantized models, real GPT-Live caption timing, playback buffering. ECAPA is a diagnostic, not perceived similarity, and it may reward copying the reference's emotional delivery.

Evidence: [80 ms summary](results/80ms/summary.json), [80 ms results](results/80ms/results.json), [scores](results/80ms/evaluation.json), [environment and crops](results/80ms/environment.json), [40 ms](results/40ms/). Audio stays in ignored `output/` and `output-fast/`.
