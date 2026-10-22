# Qwen3-TTS PAD restart: target lookahead and trailing reference silence

## Question

[The PAD-prefill comparison](../qwen3-tts-pad-prefill-compare/README.md) found that `pad_restart` (complete reference prefilled with its transcript and TTS PAD, then `tts_BOS + codec_PAD`, then the first real target token over `codec_BOS`) starts after one target token and keeps much of the voice, but long-text outputs begin with extra speech. A listener identified that speech as the end of the reference utterance, and that lab's decoder test showed it is already in the generated codec tokens, not produced by decoder priming.

Hypothesis: at `codec_BOS` the talker has seen one target token, and the most recent real text and audio it has seen are the end of the reference, so it continues the reference. Two independent levers are tested, alone and combined:

- **Target lookahead k** (0, 4, 8, 16): before `codec_BOS`, add k rows of the first k target tokens over `codec_PAD`, so the model has read the start of the new text before audio starts. Then token k+1 goes over `codec_BOS` and one token per generated frame follows. The startup requirement becomes k+1 tokens. `k=0` is identical to `pad_restart`.
- **Trailing silence** (`_sil`): append 0.8 s of digital silence to the audio used for ICL codes and decoder priming, so the reference ends with a pause instead of 0.1 s after the last word. The transcript is unchanged; the x-vector still comes from the unmodified reference.

Neither lever crops the reference, inserts dummy text, or emits EOS before the input is closed. Both layouts are untrained; their safety is what is measured.

## Conditions

Same as the PAD-prefill lab: nonquantized Base 1.7B bf16 at a fixed revision, the same private 10.678 s reference and transcript, Japanese, causal live-text adapter, tokenizer pre-token commit rule, EOS suppressed until all target text has been fed, 4-frame PCM chunks, sampling 0.9 / top_k 50 / top_p 1 / repetition penalty 1.05, 500-frame cap, 2 s idle after preparation before text starts. Short (45 chars) and long (125 chars) texts at 80 ms/character with seeds 42/43/44, plus a seed 42 full-input control. Mode order rotates per seed. One seed 0 warmup per mode is excluded. The current causal ICL is rerun as control. A 40 ms/character run is not repeated: in the predecessor labs it reproduced the 80 ms audio exactly and only changed timing.

`live.py` and `pad_live.py` are copied from the PAD-prefill lab; the only additions are `prepare_lookahead_session` (a longer bridge: k × `codec_PAD` then `codec_BOS`) and an x-vector source argument for `prepare_clone`. The generation loop is unchanged.

## Measurements

- **Leak**: Whisper large-v3-turbo transcript, normalized. Find the first 12 characters of the target; count characters heard before it and the longest run of the reference transcript inside that prefix (same rule as the predecessor's decoder diagnosis). A run of 4 or more is counted as a leak. If the target's start is not found, the whole transcript is the prefix.
- CER over the whole output, independent ECAPA-TDNN cosine against the complete reference, first PCM, simulated first voiced playout, stall sum without buffer, EOS / frame cap.
- Human listening via `output/listen.html` (not blinded). ASR, leak counts and cosine are diagnostics.

ASR text can contain the private reference transcript, so `results/` keeps counts, CER and hashes only; raw ASR stays in ignored `output/`.

## Run

```sh
export REFERENCE_WAV=/path/to/reference.wav
export REFERENCE_TRANSCRIPT_FILE=/path/to/transcript.txt
mise run run
uv run python -m http.server 8792   # then open output/listen.html
```

## Results (2026-10-22)

**参照の末尾に無音を足すと、冒頭に参照の発話が混ざるのはほぼ止まった（長文 12 回中 5 回 → 1 回）。本文の先読み k は混ざりに効かなかった。** ただし長文には、これとは別の 2 つの崩れが残る。どの PAD の方式でも 3 文目に入ったところで 2 文目へ戻って読み直す（12 回中 7〜8 回）。無音を足した方式では、途中で話し終えてしまう回もある（12 回中 3 回）。今の ICL ではどれも起きていない。短文はすべての方式で読みが正しく（CER 0）、混ざりも戻りも無い。

Apple M4 Max 128GB, macOS 27.0.1, Python 3.12.11, MLX 0.32.4, mlx-audio 0.6.1, transformers 5.20.2. kiapi was running but idle; not an exclusive-GPU measurement. A watcher sampled every 20 s for other bench/evaluate processes and found none. 72 measured generations and 9 warmups all ended with codec EOS, no errors, no frame cap, no clipped samples. As in the predecessor labs, the seed 42 character-input outputs are byte-identical to the full-input outputs in all 18 pairs (the adapter waits instead of stepping), so full-input controls add no independent quality samples.

### Long text (125 chars), 80 ms/character, seeds 42/43/44

"Leak": the ASR prefix before the target's start contains ≥ 8 consecutive characters of the reference transcript. (A 4-character run also appeared once for the current ICL when ASR missed the anchor, so 4 was too loose.) "Loop": the second sentence (`ゆっくりでいいからね`) is heard twice. "Cut": CER ≥ 40 %, i.e. the output ended early, losing roughly half the text.

| mode | wait tokens | first voice | leak | loop | cut | CER per seed | ECAPA mean |
|---|---:|---:|---:|---:|---:|---|---:|
| `icl` (control) | 105 | 11.99 s | 0 | 0 | 0 | 1.7, 0.0, 1.7 % | 0.744 |
| `pad_k0` (= pad_restart) | 1 | 2.54 s | 2 | 1 | 0 | 14.8, 31.3, 20.9 % | 0.699 |
| `pad_k4` | 5 | 2.59 s | 1 | 2 | 0 | 13.0, 24.3, 25.2 % | 0.715 |
| `pad_k8` | 9 | 2.60 s | 1 | 2 | 0 | 26.1, 25.2, 14.8 % | 0.759 |
| `pad_k16` | 17 | 3.55 s | 1 | 2 | 0 | 13.0, 22.6, 22.6 % | 0.721 |
| `pad_k0_sil` | 1 | 2.54 s | 0 | 1 | 2 | 47.8, 50.4, 23.5 % | 0.642 |
| `pad_k4_sil` | 5 | 2.64 s | 0 | 2 | 1 | 24.3, 51.3, 37.4 % | 0.713 |
| `pad_k8_sil` | 9 | 2.65 s | 1 | 2 | 0 | 12.2, 21.7, 24.3 % | 0.737 |
| `pad_k16_sil` | 17 | 3.54 s | 0 | 3 | 0 | 25.2, 27.0, 22.6 % | 0.735 |

- **Leak**: 5 of 12 runs without silence, 1 of 12 with silence (that one is an 8-character run). Lookahead k = 4–16 did not reduce it relative to k = 0 beyond what three seeds can resolve (1/3 vs 2/3). The silence result is consistent with the hypothesis that the talker continues an utterance that, in the reference, ends only 0.1 s before the audio does. Interpretation, one reference.
- **Loop**: after the start of the third sentence the talker returns to the middle of the second sentence and re-reads about 25 characters, then continues correctly to the end. It occurs at the same place across seeds and in both silence settings, and in the full-input controls. It accounts for most of the remaining CER. Neither lever affects it. It did not occur in the current ICL here, nor in the x-vector-only mode of [the same-reference x-vector comparison](../qwen3-tts-live-xvector-compare/README.md), which feeds text the same way; it appears specific to the PAD-restart layout with the reference in context.
- **Cut**: only with silence and k ≤ 4. Output stopped after about 11 s with EOS once all target text had been fed, before speaking about half of it. EOS is allowed as soon as the last target row is fed, while speech lags the fed text; the extra silence may make an early stop more likely. Not separately tested.
- **Speed**: k adds the wait for k more tokens. Long-text first voice stays about 2.5–2.7 s up to k = 8 and is 3.5 s at k = 16 (vs 12.0 s for ICL). On the short text (25 tokens) k = 16 starts only after `text.done` (4.2 s). Stalls without buffer were 3.0–3.5 s for all PAD modes on the long text.
- **ECAPA** of PAD modes on the long text is 0.64–0.76, overlapping the current ICL (0.744); `pad_k0_sil` is lowest partly because two of its outputs are cut short.

### Short text (45 chars)

All 27 PAD outputs read correctly (CER 0), with no leak and no loop. First voice (median): 1.57 s for k = 0, 2.3–2.5 s for k = 4–8, 4.2 s for k = 16, versus 4.96 s for ICL. ECAPA means 0.66–0.77 versus ICL 0.749; per-seed spread is wide (one `pad_k8_sil` output scored 0.481).

### Conclusion and limits

Trailing silence on the ICL reference is the useful lever found here: it largely removes the reference-tail leak at no latency cost. Target lookahead is not worth its latency for this purpose. PAD restart is still not usable for long replies because of the backtrack loop, which is now the main problem, and because silence introduced early stops. Candidate next steps, untested: an EOS guard that also requires speech to have caught up with the fed text (to target the cut), and a lighter repetition safeguard or a text-feed pacing limit (to target the loop, if it is caused by the text running far ahead of speech in this layout).

Not checked: human listening (the page `output/listen.html` is generated; no ratings assigned), other silence lengths, other references or speakers, more seeds, quantized models, real GPT-Live caption timing. ASR leak/loop counts are heuristics on Whisper output.

Evidence: [summary](results/80ms/summary.json), [results](results/80ms/results.json), [scores without ASR text](results/80ms/evaluation.json), [environment](results/80ms/environment.json). Audio and raw ASR stay in ignored `output/`.
