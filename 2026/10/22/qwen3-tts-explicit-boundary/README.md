# Qwen3-TTS explicit reference and target boundaries for live cloning

## Objective and protocol

The listener finds the PAD-restart voice acceptable but hears the end of the reference before the new text. Keep the full10.678-second reference unchanged. Test whether explicit reference-ending/target-starting tokens remove that prefix while retaining voice and live input/output.

Controls: causalICL and the priorpad_restart. Candidate grid: (1)textEOS immediately after reference text, before remaining PAD rows; (2)codecEOS after all reference audio code rows, paired with textPAD; (3)both; (4)both plus a fresh role/language/speaker prefix before firsttarget+codecBOS. These are experimental input layouts, not claims of upstream multi-utterance support. TargetEOS is only fed after actual target text.done; codecEOS remains suppressed until target text/EOS have been consumed. Ref-textEOS is a reference boundary, not target completion.

Pilot: two fixed Japanese prompts,80ms/Unicode character,seed42, same sampling(.9/topk50/topp1/penalty1.05), samefullBasebf16 checkpoint, same4-frame output chunks, full decoderreferencepriming, max500frames. Warm up eachmode withseed0; exclude those from measurement. Hold preparedstate for2seconds beforetimedtext input. If one candidate reads all text without addedprefix and does not materially degrade speaker diagnostics, test additional seeds and a thirdtext. Preserve failures; no favorableaudio cherry-picking.

A separate top-level experiment is using the M4 machine, so this experiment runs on an AppleM1Max with fresh same-machine controls. Do not compare absolute timings directly with priorM4 results. The pad_restart control must reproduce prefix leakage here before claiming a candidate removed it. No physical playback; ASR/reference-overlap counts and independent speaker encoders are diagnostics. Human naturalness scores are not invented. Full reference/transcript, generatedWAVs and unexpectedASR remain ignored/private. Only counts/hashes/metrics and generic target prompts are published.

All source is copied into this lab from [the PAD experiment](../qwen3-tts-pad-prefill-compare/README.md); no runtime imports from otherlabs orkiapi. Production remains unchanged.

**有望な境界の組合せが見つかった。参照文と参照音声を閉じ、新しいrole/language/speaker prefixを入れ直すと、M4の3本文×3seedで参照末尾の混入を検出しなかった。** 同じ参照全量を使う。これは小さいlab検証であり、本番の通話sessionは変更していない。

## Run and interpretation

```sh
export REFERENCE_WAV=/path/to/complete-reference.wav
export REFERENCE_TRANSCRIPT_FILE=/path/to/reference-transcript.txt
mise run run --seeds 42 --schedules chars --output output-pilot
uv run python evaluate.py --reference "$REFERENCE_WAV" --reference-transcript "$REFERENCE_TRANSCRIPT_FILE" --output output-pilot --asr
uv run python audit.py --output output-pilot
uv run python replay.py --output output-pilot
```

Dependencies are fixed by `uv.lock`; model is mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16 at a6eb4f68e4b056f1215157bb696209bc82a6db48. Reference WAVSHA256c03e2da1cf1877fc829168840d894fb846716c69d80d4f00ae4cdaafea96a5c0,256283mono24k samples,10.678458seconds. Private reference/transcript are not distributed; reproduction with another reference is a different-reference test.

The waveform reference and decoder priming are identical across modes. Reference textEOS replaces onePAD row inside reference prefill; audioEOS is an extra talker-only row after full reference codes. BothEOS plusfreshprefix reuses the original role/language/full-reference-speaker/ttsBOS-codecPAD prefix instead of the single restartrow. Only generated acoustic codes go to the decoder; boundaryEOS is never decoded as audio. This is experimental conditioning, not a validated multi-turn chat format.

FirstPCM may be silent or wrong text. `audit.py` estimates first voiced playout from measured chunk arrivals and first10msRMS>.003. Startup model/reference preparation and deliberate2second wait are excluded from this input-start clock and recorded separately. No extra playbackbuffer is assumed in gap simulation. Actual appendtimestamps, not nominal scheduling alone, determine timing.

FixedWhisper large-v3-turbo(a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb),temperature0,Japanese diagnoses reading. CER uses NFKC/lowercase/punctuation/symbol/whitespace removal; spelling variants can count. Prefix detection aligns a matching block of at least8characters within the first4normalized targetcharacters, allowing a small ASR omission at the beginning; it counts preceding outputcharacters and their reference overlap. Unknownalignment is null, not success. Reference-overlap counts and CER do not replace listening.

IndependentECAPA-TDNN192d uses `pranjal-pravesh/ecapa_tdnn_onnx` revision04c3ffe4fd00b3b7853fd57db44e2e531d4817f2/SHA256245eb5995cfffd74494862dee33da2b00c1c2579eb0c6703847784e9901ed458, raw16k waveform, CPU. Optional second independent WavLM-Large+ECAPA256d int8 uses `kiarina/MeanVC2-ONNX` revision2db97430c6e315a819daa30e255e14615205a3d1, `speaker/speaker.int8.onnx`, SHA256ccd31b45eb2162937b94921d6e64fdd2cf5bf77193ad6f738e85f06a914a95ca. Give its path to `evaluate_wavlm.py --model`. Cosine is a diagnostic, not a human similarity percentage. No human naturalness ratings are assigned.

`*-listen.wav` contains concatenated generated PCM for listening; `*-arrival.wav` retains startup/gaps. Raw unexpected transcripts and clone audio stay ignored/private. `publish.py` exports counts/hashes instead of nonmatching transcript strings, preserving every metric/failure. No production code or settings are changed.

## Screening and validation decision

M1seed42 pad_restart did not reproduce the reference-tail phrase, so the M1screen cannot establish removal. Text/audioEOS-only candidates caused repetition, while freshprefix read the long prompt with only small ASR differences. Additional M1seeds43/44 showed substantial control repetition but no reference-tail phrase. Keep this limitation.

Once the M4 comparison machine was free, run paired pad_restart/freshprefix on longseed42. The pad_restart control reproduced the prior floatPCMhash exactly and the17-character introduction/15-character reference overlap. Freshprefix removed that phrase (ASR prefix differs only by the elongation in 'うん/うーん'), with ECAPA0.742 versuscontrol0.690. This selects the combination for further validation, not each component as necessary.

Next validate on M4 with short/long/third prompts and seeds42/43/44. Reuse the two just-measured longseed42 rows using --skip-stems, include fresh ICL/PAD controls atseed42, and add freshprefix-only seeds43/44. A new third prompt was fixed before this extension. This is exploratory selection followed by small validation, not proof across speakers or a production session.

## Results (2026-10-22)

### Effective combination

The selected `fresh_prefix` performs:

1. Full reference transcript, its textEOS, and remainingTTS PAD over all reference codec rows.
2. A talker-only reference codecEOS paired with textPAD.
3. A fresh role/language/speaker prefix using the same full-reference speaker embedding.
4. Wait for real text; first target token over codecBOS, then causal text/audio continuation.

The full referenceKV context is retained. Reference waveform, transcript and speaker identity are unchanged; nothing is trimmed and no dummy speech is generated. This does not prove each component individually necessary, nor an officially trained multi-utterance format. It identifies a combination that worked in the following small comparison.

### Control validity and hardware

M1Max64GB/macOS27.0.1,Python3.12.10 was used while a separate M4 experiment ran. Its seed42PAD control did not reproduce the reference-tail phrase. Extra seeds43/44 showed control repetition, but not the original phrase. These M1data support screening only; they do not establish removal. TextEOS/audioEOS alone or together without a freshprefix produced long-prompt repetition (CER roughly22–24% in the pilot).

After the other experiment finished, the decisive check used M4Max128GB/macOS27.0.1/Python3.12.11,MLX0.32.4/mlx-audio0.6.1/transformers5.20.2. The originalPAD seed42long control exactly reproduced the prior floatPCM SHA256e4ca1414d8f9389bd160b27e5ff03895af3f7265067dffdf18a82bfeeb79b506. ASR found17extra prefixcharacters, with15characters matching the reference. Thus the original failure was present on the same backend before judging the new boundary.

The same paired freshprefix output had no reference-tail phrase. Its only ASR change was the elongation in「うん→うーん」. Additional short/long/third prompts atseeds42/43/44 gave9candidate utterances. The initial longseed42 row was reused, not regenerated in the extension. All9ended atEOS after consuming alltarget/EOS rows, had finitePCM and0clipped samples, and emittedPCM beforetext.done.

Total:33distinct measured rows—M1pilot12+validation4; M4three-control/candidate set15+fastschedule2. Separate warmups15 are excluded. M4individual runs and their environments are retained inside the combined environment file. There was no physical playback or realGPTLive call. Timing is input-start toPCM, not end-to-end conversation latency.

### Prefix and reading

**Reference-tail phrase: not detected in any of9freshprefix outputs.** Longreference overlap anywhere in ASR was at most4characters, also found in ordinary target/control text; the prior15character phrase did not occur. Prefix alignment and whole-ASR reference-overlap were both checked.

| Text | Candidate seeds | ASR differences |
|---|---|---|
| short45characters |42/43/44|CER0 in all3|
| long125characters |42/43/44|One initial-character difference per output:「うん→うーん」「うん→ん」「うん→ふん」; CER0.87%|
| third64characters |42/43/44|「持っていきます→持って行きます」 spelling; CER1.69%|

The candidate is not claimed to be character-perfect or perceptually identical. These ASR differences need listening, especially the first syllable. They are distinct from repeating the reference's last message. No new sentence or repeated passage was found in these candidate ASRs. In contrast, the originalPAD thirdtextseed42 output had substantial ASR repetition (CER196.6%); the freshprefix thirdtext did not.

### Voice similarity

Same3texts/seed42 onM4, matched control/candidate pairs, fullreference versus entire output. Higher is closer within each encoder; scales are not interchangeable.

| Independent encoder | CurrentICL | OriginalPAD | Explicit ends + freshprefix |
|---|---:|---:|---:|
| ECAPA192d mean |0.768|0.700|0.750|
| WavLM+ECAPA256d mean |0.834|0.790|0.819|

For the originally failing longseed42, ECAPA was0.690→0.742 (ICL0.748). The new candidate is closer on these paired averages than originalPAD, though still slightly belowICL. Across all9candidate outputs ECAPA ranged approximately0.636–0.794, showing seed/text variation. These measurements do not replace the listener's assessment that PADvoice is acceptable. Human naturalness/identity scores have not been assigned.

### Warm start timing

M4,80ms/Unicode character,3seeds, freshprefix medians (ranges):

| Text | FirstPCM | Simulated voiced start | Input-starvation gaps |
|---|---:|---:|---:|
| short |1.498s(1.480–1.515)|1.535s(1.500–1.548)|1.54–1.57s|
| long |2.475s(2.428–2.490)|2.505s(2.458–2.530)|2.94–2.96s|
| third |0.690s(0.686–0.711)|0.730s(0.716–0.741)|2.66–2.74s|

Longseed42originalPAD firstPCM2.486s versusfreshprefix2.475s: boundary addition did not increase the initial text wait in this pair. PreparedKV/decoder time was about0.195s, followed by deliberate2second idle before text. The original105target-token requirement becomes1committed token. Tokenizer boundaries and4codecframe emission still delay output; it does not promise sound from the first character.

At40ms/characterseed42, short firstPCM0.896s/voiced0.946s/gap0.387s; long firstPCM1.419s/voiced1.449s/gap0. The waveform hashes were identical to the corresponding80ms outputs. Slower text supply still causes gaps; changing boundaries solves neither input starvation nor a playbackbuffer policy.

### Scope and next validation

This combination is a useful candidate for continued call integration: fullreference, preparation before text, early live output, and no detected reference-tail phrase in this sample. It is not a guarantee for other speakers, very short interjections, long responses, arbitrary cuts, or allseeds. Multi-utterance sessions, EOS-to-next-utterance behavior, interruption, cache reuse/eviction, realcaption delivery and microphone/AEC have not been tested here. No production changes.

Evidence: [M4combined measurements](results/m4-combined/results.json), [ASR/ECAPA](results/m4-combined/evaluation.json), [WavLM](results/m4-combined/wavlm-evaluation.json), [40ms](results/m4-fast/results.json), [M1screening](results/pilot/results.json), [M1validation](results/validation/results.json). Unexpected ASR strings are withheld from publicJSON while their metrics/hashes are retained; unmodified audio and rawASR stay in ignored outputfolders. The private reference is not published.
