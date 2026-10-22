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
mise run followup        # loop diagnosis: lead analysis, text pacing, wording variant
mise run followup-crop   # loop diagnosis: short ICL segment
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

Follow-up below (diagnosing the loop) was registered and run after these results.

Not checked: human listening (the page `output/listen.html` is generated; no ratings assigned), other silence lengths, other references or speakers, more seeds, quantized models, real GPT-Live caption timing. ASR leak/loop counts are heuristics on Whisper output.

Evidence: [summary](results/80ms/summary.json), [results](results/80ms/results.json), [scores without ASR text](results/80ms/evaluation.json), [environment](results/80ms/environment.json). Audio and raw ASR stay in ignored `output/`.

## Follow-up protocol: why does the long text loop back? (registered before running)

Scope: trailing silence kept (`_sil`), modes `pad_k0_sil` and `pad_k16_sil` (k16 looped 3/3 without cut-offs; k0 is the minimal-latency layout). Two hypotheses:

1. **Text lead.** Text is fed one token per generated frame (12.5 tokens/s) whenever available, while this speech runs about 3.8 tokens/s. At 80 ms/character text arrives about 8 tokens/s, so by the third sentence the talker has read far ahead of what it is saying (with full input, all text is fed within the first ~6.5 s of frames). If the loop comes from losing its place, it should depend on how far ahead text has been fed.
   - *Analysis of existing outputs* (no new generation): Whisper word timestamps locate where the second reading starts; from the trace, compute how many target tokens had been fed at that frame and how many the speech had reached.
   - *Text pacing* (revised before running): changing the arrival rate cannot test this, because the talker consumes exactly one text row per generated frame whatever the arrival rate; slower arrival only pauses frames (the 40 ms and 80 ms runs were byte-identical). Instead change the sequence: feed a real target token at most every N frames (N = 2, 3) and a TTS PAD text row on the frames in between, so text advances about 6.3 or 4.2 tokens/s of audio, near the speech rate, and is not exhausted early. Untrained interleaving; N = 1 is the existing layout. Long text, full input and 80 ms/character, seeds 42/43/44.
2. **Ambiguous repeated wording.** The jump goes from `しんどいって` (before `言っていいんだよ`) back to `…しなくていいし、ゆっくりでいいからね`, a similar `〜ていい` construction. *Text variant*: the long text with only `言っていいんだよ` replaced by `言ってもかまわないよ`, everything else identical, 80 ms/character and full input, seeds 42/43/44, plus the current ICL as control. If ambiguity drives it, the loop should disappear or move.

Loop/leak/cut counting and privacy rules are as above. One reference, three seeds per cell; results are indicative, not statistical.

## Follow-up results (2026-10-22)

**戻りの原因は、文脈に入れている長い参照だった。ICL の参照を 2.2 秒の節にすると、長文 6 回すべてで戻りが消えた。ただし、声の類似度も埋め込みのみ以下まで下がった。** 戻りは本文をすべて入れ終えた後に起きる（どの回も同じ）。本文の進みを PAD で遅らせると話が完全に崩れ、言い回しを変えても戻る場所と戻り先は変わらなかった。 戻りは「しんどいって」の直後に、前の「無理しなくて」の続き（「いいし、ゆっくりでいいからね」）を話す形で起きる。

### Where the loop happens (existing outputs, no new generation)

Whisper word timestamps put the end of the first `しんどいって` at 9.0–12.0 s of audio in looping runs and 11.1–15.1 s in the others. At that point every PAD run, looping or not, had already fed all 79 target tokens: text is fed one token per frame from the start, so it is exhausted at about 6.3 s of audio (k = 0) while the speech has reached token 39. The talker is therefore always reading the rest of the text from rows it consumed earlier when the loop happens, about 40 tokens ahead of what it is saying. This is identical in looping and non-looping runs, so it is a precondition at most, not an explanation of which runs loop. The current ICL also has the full text in context (prefilled) and does not loop. Evidence: `results/loop-lead.json`.

### Text pacing with PAD rows: not viable

All 12 paced runs (`_p2`, `_p3`, k = 0 and 16, full input and 80 ms/character) reached the 500-frame cap (40 s) instead of ending. ASR shows the first sentence read with stutters, then degenerating into repeated syllables or words (for example the same 1–3 characters dozens of times). With k = 0 the reference-tail leak (≥ 8 characters) also returned in 3 of 6 runs. Interleaving TTS PAD text rows between real text rows is outside what the model handles, so this does not test the lead hypothesis and is not a usable remedy. Evidence: `results/pace-80ms/`.

### Changed wording: loop unchanged

With only `言っていいんだよ` changed to `言ってもかまわないよ` (`long_alt`), the PAD runs still looped at the same place and to the same place: after `しんどいって` they continued `いいし、ゆっくりでいいからね…`, the words that follow `無理しなくて` in the second sentence, then re-read correctly to the end. `pad_k16_sil`: loop 3/3 (plus full input, identical to seed 42). `pad_k0_sil`: loop 1, early cut 1, and one run (seed 42, identical in full input) that read the text and then continued with a repeated syllable until EOS at 35 s. The current ICL read the variant correctly 3/3 (CER ≤ 3 %, spelling differences only). The loop is therefore not triggered by the upcoming `〜ていい`; what both jumps share is the `〜って` / `〜くて` just before it, after which the talker continues from the earlier `無理しなくて`. That reading is an interpretation of ASR output. Evidence: `results/alt-80ms/`.

### Added before running: does the reference context drive the loop?

After the pacing and wording runs (results below), one more contrast was registered. The x-vector-only mode feeds text exactly like PAD restart and did not loop in [the x-vector comparison](../qwen3-tts-live-xvector-compare/README.md); PAD restart differs mainly by holding the 10.7 s reference and its transcript in context. Test: PAD restart (`_sil`, k = 0 and 16) with the ICL segment cut to the reference's last clause (2.18 s, 8.5 s–end) or last sentence (4.08 s, 6.6 s–end), each plus the same 0.8 s silence, x-vector from the complete reference, transcript sliced to match (as in [the cropped-ICL lab](../qwen3-tts-icl-crop-xvector/README.md)). Long text, 80 ms/character seeds 42/43/44 plus full input. If the loop rate falls with a shorter segment, the reference context is implicated.

### Short ICL segment: the loop goes away, and so does similarity

| mode (all `_sil`, x-vector from the complete reference) | ICL segment | loop | leak | CER per seed | ECAPA mean (range) |
|---|---|---:|---:|---|---:|
| `pad_k0_sil` (main run above) | 10.68 s | 1/3 | 0/3 | 47.8, 50.4, 23.5 % (2 cut) | 0.642 |
| `pad_k16_sil` (main run above) | 10.68 s | 3/3 | 0/3 | 25.2, 27.0, 22.6 % | 0.735 |
| `pad_k0_sil_ctail3` | 4.08 s | 0/3 | 0/3 | 0.0, 0.0, 0.0 % | 0.446 (0.324–0.519) |
| `pad_k16_sil_ctail3` | 4.08 s | 3/3 | 0/3 | 21.7, 21.7, 25.2 % | 0.688 (0.658–0.721) |
| `pad_k0_sil_cclause` | 2.18 s | 0/3 | 0/3 | 0.0, 0.0, 8.7 % | 0.632 (0.533–0.737) |
| `pad_k16_sil_cclause` | 2.18 s | 0/3 | 0/3 | 1.7, 0.0, 1.7 % | 0.550 (0.491–0.652) |

- With the 2.18 s segment, none of the 6 long-text runs looped, leaked or stopped early. The one 8.7 % CER run starts with a few garbled syllables before the text. First voice 2.8 s (k = 0) and 3.8 s (k = 16). With 4.08 s, k = 0 read cleanly 3/3 but k = 16 looped 3/3, at the same place as before.
- So the amount of reference held in context drives the loop: the full 10.7 s reference loops in most runs, the 2.18 s clause in none. Together with the x-vector-only mode never looping, this points to the talker drawing on the reference (or its transcript rows) when it has to locate its position in already-consumed text. That is an interpretation; attention was not inspected.
- The cost is similarity. ECAPA for the short segments is 0.45–0.69 on average, at or below x-vector only (0.654 in the predecessor lab) and well below the current ICL (0.744). Several outputs score below 0.55. As [the cropped-ICL lab](../qwen3-tts-icl-crop-xvector/README.md) found for the normal layout, shortening the ICL segment gives up what made ICL attractive; here it trades one failure (loop) for the other (similarity). Not judged by ear.

### Follow-up conclusion

The long-text loop in PAD restart is caused by the long reference in context, not by the upcoming wording, and it happens after all text has been consumed. Two cheap levers were ruled out: pacing text with PAD rows (breaks generation) and lookahead k (does not help, and k = 16 made the 4.08 s segment loop). Removing the loop by shortening the reference costs the similarity that PAD restart was meant to keep. Within this untrained layout no setting tried so far gives full-ICL similarity, no leak and no loop on the long text at the same time. Remaining options outside this lab's scope: splitting replies into sentences and restarting per sentence (each sentence is short, where PAD restart had no loop in any run), or adapting the model to the layout (for example self-distillation from the current ICL).

Evidence: [lead analysis](results/loop-lead.json), [pacing](results/pace-80ms/), [wording variant](results/alt-80ms/), [short segment](results/crop-80ms/). Raw ASR and audio stay in ignored `output*/`.
