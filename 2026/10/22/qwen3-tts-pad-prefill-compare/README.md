# Same-reference Qwen3-TTS: PAD prefill before live text

## Questions and preregistered comparison

Can we keep the complete10.678-second reference and its transcript, prefill its missing text rows with dedicated TTS PAD before actual text arrives, then resume live text without the current105target-token startup requirement? The reference is not cropped. PAD is a model embedding, never whitespace, never dummy spoken text. No targetEOS is inserted until explicit text.done. No audio codes are sampled before real text arrives.

Current causalICL is the control. Two candidates are evaluated in a small pilot:

- **pad_last**: overlay reference text then TTS PAD on reference codec rows, prefill all except the last reference-code row. On first real token, overlay it on that final reference-code row and predict first generated codec. Subsequent real text is fed one row per generated codec.
- **pad_extra**: prefill all reference codec rows with reference text then TTS PAD. Resume with first real token over codecPAD (one new text-only row), then generate normally. This extra special row is a distinct hypothesis, not assumed trained behavior.

Both change text/audio alignment from the official causalICL layout. Neither is an upstream-supported continuation guarantee. Full reference decoder priming and full speaker embedding are retained. Evaluate quality rather than assuming PAD is semantically neutral.

Pilot uses fixed short/long Japanese prompts, seed42, full and80ms/character inputs; currentICL is rerun in the same process. Warmupseed0 is excluded. If results are coherent, evaluate the structurally simpler pad_last with seeds42/43/44 and repeat40ms/character atseed42. Retain pilot failures and cap termination; do not select individual successful audio clips. Same nonquantizedBase1.7B checkpoint/revision/dependencies/sampling/chunk size as [the same-reference x-vector comparison](../qwen3-tts-live-xvector-compare/README.md). All source is copied into this lab; no runtime imports from priorlabs orkiapi.

Measurements: pre-text prefill time separately; firstPCM and simulated voiced start from real input start; before/after inputdone; arrival gaps; full waveform independentECAPA192d cosine; fixedWhisper reading/CER; finite/peak/EOS. Same reference hashes and length, no private reference/transcript committed. GeneratedcloneWAVs are ignored. Naturalness requires human listening; ASR/cosine are diagnostics only. No speaker playback or production changes.

Current results: PAD-only continuation failed; adding a start boundary resumed speech but introduced extra words in long prompts. See [results](#results-2026-10-22). Production is unchanged.

## Pilot update before the additional candidate

Both original candidates returned short/mostly-silent output instead of reading the text in the pilot. A third, explicitly separate hypothesis is therefore tested: **pad_restart** prefills all reference rows with ref_text/PAD, appends `tts_BOS + codec_PAD`, waits, then resumes with first real target token over `codec_BOS`. This adds a new speech-start boundary while retaining the whole reference KV context. It is not described as equivalent to the trained causal layout. Keep the two failures; do not reinterpret their early PCM as successful speech.

## EOS-consumption guard, registered before retest

The first pilot allowed codecEOS as soon as the producer closed input. Unlike originalICL, PAD variants have not yet fed the remaining target text into the talker at that moment. Early termination can therefore leave most input unconsumed. The corrected variants suppress codecEOS until real target tokens and their explicit EOS row have been fed (`closed and cursor > len(target_ids)`). This does not pad unknown text or invent spoken content. Keep v0pilot evidence and rerun the same conditions; `--legacy-eos` reproduces the original guard. Report changes as a new implementation version, not drop failures. Structural text-consumption checks precede quality claims.

The same all-text-consumed guard is also applied to controlICL with its absolute cursor (`closed and cursor > ref_text_count + target_count`). For these short/long controls, all target text/EOS fits inside reference prefill, so the guard is initially satisfied and does not alter the observed control PCM. This is a live-session input-consumption policy, not a claim that upstream always suppresses earlyEOS.

## Main-candidate decision, before repeated evaluation

The guarded short-text pilot gave CER≈0.88/0.95 for pad_last/pad_extra and CER0 for pad_restart. IndependentECAPA for pad_restart was0.677 versus control0.771 on seed42 short text, so preserving similarity is already doubtful. Select pad_restart for repeated short/long evaluation because it reads the supplied text, not because its similarity is best. Keep all other candidates in pilot results. Run ICL+pad_restart at80ms/character with seeds42/43/44, full-input controlseed42, two seconds idle after preparation; additionally40ms/characterseed42. No subjective ratings are assigned.

## Reproduction and metrics

```sh
export REFERENCE_WAV=/path/to/complete-reference.wav
export REFERENCE_TRANSCRIPT_FILE=/path/to/reference-transcript.txt
mise run run --output output-main
uv run python evaluate.py --reference "$REFERENCE_WAV" --output output-main --asr
uv run python audit.py --output output-main
uv run python replay.py --output output-main
```

`uv.lock` fixes dependencies. Model: mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16, revisiona6eb4f68e4b056f1215157bb696209bc82a6db48. Private input:256283mono24k samples,10.678458seconds, WAVSHA256c03e2da1cf1877fc829168840d894fb846716c69d80d4f00ae4cdaafea96a5c0. Reference transcript is60characters and is not distributed. Exact reproduction requires the same privately held inputs; other authorized references are different-reference tests.

All variants use languagejapanese, temperature0.9, top_k50, top_p1, all-history repetition penalty1.05, four-frame chunks and500-frame cap. Preparation does not sample generated audio. Main runs idle2seconds after preparing referenceKV/decoder before starting timed text delivery. Warmupseed0 is excluded. Default80ms Unicode-character schedule uses seeds42/43/44; full-input controlseed42. Secondary40ms schedule uses seed42 only. FirstPCM is not necessarily voice. `audit.py` simulates first voiced playout from measured chunk arrivals and first10ms RMS>.003; no device/network/physical-microphone timing. `gap_s` simulates immediate playout with no additional buffer. PCM is never time-stretched.

`*-listen.wav` is concatenated generated audio converted toPCM16 for voice/prosody comparison. `*-arrival.wav` includes startup wait and measured gaps. No human listening ratings are assigned; `listening.csv` is left blank. ASR is fixed Whisper large-v3-turbo(a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb), temperature0, languageja. Hash-identical16kPCM is transcribed once/reused. NFKC/lowercase/punctuation/symbol/whitespace removal precedesCER; spelling variants can count as errors. No audible output is recorded as empty ASR without hallucination-prone silence transcription.

Primary independent speaker diagnostic: ECAPA-TDNN192d, `pranjal-pravesh/ecapa_tdnn_onnx` revision04c3ffe4fd00b3b7853fd57db44e2e531d4817f2, SHA256245eb5995cfffd74494862dee33da2b00c1c2579eb0c6703847784e9901ed458. Cosine is withheld for output shorter than1second or with less than0.5seconds of10msRMS>.003, because silence/reference decoder tail is not a meaningful speaker comparison.

Second independent speaker diagnostic: WavLM-Large+ECAPA256d int8, `kiarina/MeanVC2-ONNX` revision2db97430c6e315a819daa30e255e14615205a3d1, `speaker/speaker.int8.onnx`, SHA256ccd31b45eb2162937b94921d6e64fdd2cf5bf77193ad6f738e85f06a914a95ca. CPU-only `evaluate_wavlm.py --model PATH --reference "$REFERENCE_WAV" --output output-main` reads raw16k waveform and normalizes its256d output. Weights are not distributed. Both independent scores are diagnostics, not human similarity ratings or MOS. Qwen's own embedding cosine is supplementary only.

The control and newlayouts share model modules. The newlayout is an intentional distribution change, so no cross-framework numerical equivalence is claimed. Unknown text is never filled with EOS in advance. This tests one initial generation with text waiting/resumption; not multiple completed utterances, arbitrary post-EOS continuation, or a production long-lived WebSocket session.

## Results (2026-10-22)

**PADで参照を先に処理して後から本文を続けること自体はできたが、今回の3配置では、現ICLの読みと類似度を保つ解決にはならなかった。** そのまま続ける配置は本文を無視/反復し、開始境界を追加した配置も長文で余分な発言が混ざった。

実行: Apple M4 Max128GB、macOS27.0.1、Python3.12.11、MLX0.32.4、mlx-audio0.6.1、transformers5.20.2、numpy2.5.4。通常サービスを変更しない別process。GPUを占有した隔離測定ではない。独立WavLM評価は別のApple M1 Max上のCPU、Python3.12.10/ORT1.27.0/numpy2.5.1。再生・実マイク・ネットワーク・実GPT-Liveは測定外。

### 失敗も含む候補比較

| 配置 | 短文の観測 |
|---|---|
| pad_last（最終参照codec行に最初の実textを重ねる） | 初期実装はほぼ無音で早期EOS。全text消費guard後も本文と違う発言になり、full/charの両方が500frame capに到達。ASR CER約88%、40秒の出力 |
| pad_extra（全参照後、実text+codecPAD） | 初期実装は短い声/無音。guard後も期待本文を読まず、ASR CER約95% |
| pad_restart（全参照後、開始境界を明示） | 短文は読める。主比較へ進めたが、長文3seedで余計な発言/読み違いが出た |

44計測発話（初期pilot12、restart追加pilot4、guarded短文pilot8、主比較16、速い入力4）と、別にseed0warmup12。guarded pilotのcap2件も保存した。EOSで終わることと、指定本文を話せることは区別する。PADの早期PCMを成功と数えない。

### 開始時間：主比較

同じ参照全体・同じ2原稿・80ms/文字、seed42/43/44。中央値（範囲）。基準時刻は準備と2秒の待機の後、実本文の入力開始。初期条件はICL105token、PAD再開1token。

| 条件 | 現ICL: 初回PCM | PAD再開: 初回PCM | 現ICL: 発声開始推定 | PAD再開: 発声開始推定 |
|---|---:|---:|---:|---:|
| 短文45文字 |4.238秒(4.199–4.249)|1.516秒(1.512–1.522)|4.889秒(4.798–5.219)|1.572秒(1.566–1.592)|
| 長文125文字 |11.162秒(11.146–11.191)|2.495秒(2.476–2.507)|12.021秒(11.872–12.156)|2.555秒(2.546–2.567)|

**PAD長文の最初の音には本来ない言葉が含まれる。これらは「本文を正しく話し始めるまで」の成功値ではない。** PADは全8逐次入力でtext.done前にPCMを出し、ICLは全8でtext.done後。最後の日本語pre-tokenと4codecframe分の本文は待つので、1token条件は1文字で即発声という意味ではない。

参照promptの準備0.040秒、PAD用KV/decoderの事前準備は各試行約0.195秒（model load1.795秒は別）。PAD再開では145行を準備してから2秒待っている。PAD事前処理中に生成codecをsampleせず、参照復号PCMは捨てた。準備時間込みの保証値やcold start保証ではない。

即再生の累積途切れ: ICL0、PAD短文約1.50–1.54秒/長文約2.91–2.97秒。モデル演算だけでなく後続文字の確定待ちを含む。

40ms/文字、seed42の追加試行（各1回）:

| 条件 | 現ICL PCM / 発声開始推定 | PAD再開 PCM / 発声開始推定 | PAD再開の累積途切れ |
|---|---:|---:|---:|
| 短文 |2.437 / 3.127秒|0.870 / 0.940秒|0.372秒|
| 長文 |6.143 / 6.853秒|1.404 / 1.474秒|0秒|

入力を早くすると待ちによる途切れは減るが、長文の余分な発言は残った。速い入力だけで品質問題は解決していない。

### 声の近さ

80ms/文字の各6音声、全参照対全生成波形のcosine平均。尺度間の数値は直接比較しない。

| 独立encoder | 現ICL | PAD再開 |
|---|---:|---:|
| ECAPA-TDNN192d |0.747|0.705|
| WavLM-Large+ECAPA256d |0.827|0.809|

両指標で平均は下がったが、差の大きさはencoderによって違う。一部seedではPADのほうが高く、少数2原稿での測定を一般的な聴感・統計的同等性へ換算しない。またPAD出力の余計な発言には参照文との一致があり、全波形スコアはその影響も受ける。高めの値が出ても、正しい本文を似た声で話せた証拠にはならない。Qwen自身のcosineは両方約0.97–0.98と高く、この問題を見分けられなかった。

### 日本語の読み・自然さ

| 原稿 | 現ICLのASR CER | PAD再開のASR CER |
|---|---:|---:|
| 短文3seed |0% 全3件|0% 全3件|
| 長文3seed |0–1.74%|14.78%、31.30%、20.87%|

現ICLの非ゼロには「おいしい」/「美味しい」の表記差と、冒頭「うん」の認識漏れがある。PAD長文は表記差だけではなく、入力にない冒頭の言葉や読み違いがあった。2seedでASRに参照文と連続15文字の一致を検出した。モデルによる参照内容の再生なのか、ASR誤認の寄与がどれだけあるかの完全な聴取判定はしていないが、追加音声を含む出力として採用できない。

主比較20件は全target/EOS消費をtraceで確認、codecEOSで終了、有限PCM/clipped sample0。seed42の全文/80msのPCM hashは両方式・両原稿で一致。文字送りだけが原因で長文を壊したのではなく、このPAD再開配置で全文controlにも問題が出ている。

主観的な声の似方・抑揚・自然さの評点は未実施。短文CER0でも自然さを保証しないし、自然な響きでも別の文を話すなら通話には使えない。試聴用の未加工連結PCMと到着再現PCMを残した。再生bufferは途切れを減らせても、余分な発言は直せない。

### 成立範囲と判断

この結果は「専用PADをどこかへ入れる全方式が不可能」という証明ではない。今回の3配置、1参照、2原稿、固定bf16 checkpointの結果である。しかし、単純なPAD事前埋めを実用品として採用する根拠にはならなかった。特に、PADで済ませた過去のKV位置へ後から本文を挿し戻したわけではなく、新しい位置へ続ける配置変更である。長い参照の情報を残すだけでは元ICLと同じ条件にはならない。

製品への反映なし。複数発話/EOS後の継続、長時間通話、別話者、他言語、量子化、実caption、AECは未検証。参照/生成音声は公開Gitに含めずローカルignored入力/出力へ保全。

Evidence: [main80ms](results/80ms/results.json), [ECAPA/ASR](results/80ms/evaluation.json), [WavLM](results/80ms/wavlm-evaluation.json), [40ms](results/40ms/results.json), [guarded failures](results/guarded-pilot/results.json), [v0 failures](results/pilot-v0/results.json). `export_results.py` keeps all metrics/failures but withholds nonmatching PAD ASR strings/private-reference overlaps from publicJSON; raw transcripts and waveform remain in ignored output folders. Sixteen ASR strings were withheld, not removed from evaluation.
