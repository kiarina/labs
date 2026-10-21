# Same-reference live Qwen3-TTS: causal ICL versus speaker embedding only

## Questions and evaluation plan

Keep the complete reference unchanged. Compare causal ICL (current integration) against speaker embedding only with causal live text input. Neither mode may insert EOS/pad for unknown text while input is open. Same Base bf16 checkpoint, language, tokenizer commit rule, four-frame PCM chunks, sampling0.9/top_k50/top_p1/penalty1.05, seeds42/43/44. Short and long Japanese texts, Unicode characters every80ms; a seed42 full-input control for each mode/text. Alternate mode order by seed. Reference/prompt preparation is timed separately from warm generation.

Measure first PCM and first non-silent sample arrival versus text.done; generated duration, arrival playback gaps, ASR/CER and model speaker-encoder cosine as diagnostics. Cosine is not independent of conditioning. ASR does not judge naturalness; provide unmodified WAVs for human listening. Record every failure, seed and input schedule. Do not change production or play audio through the local speaker.

The original reference and transcript are private inputs, ignored under `.input/`. Record hashes/duration, not their content. Supply `--reference` and `--transcript-file` to reproduce with your own authorized reference. Generated WAVs are ignored. No private voice data is published.

Adapter is copied into this lab from [the causal ICL experiment](../qwen3-tts-mlx-live-clone/README.md), then extended with speaker-only prompt preparation. It imports no other lab or kiapi. Speaker-only prefix uses mlx-audio0.6.1's speaker encoder, omits empty-target terminal rows and starts causal input with first target token + codec BOS; decoder has no reference-code priming. Baseline retains full reference-code priming. This comparison changes conditioning, not model weights.

## Run

```sh
export REFERENCE_WAV=/path/to/complete-reference.wav
export REFERENCE_TRANSCRIPT_FILE=/path/to/reference-transcript.txt
mise run run
uv run python evaluate.py --reference "$REFERENCE_WAV" --asr
uv run python audit.py
uv run python replay.py
```

Use a directory outside this repository for private inputs, or ignored `.input/`. `bench.py` takes explicit paths and does not contact a voice store. The experiment's private 10.678458-second reference had256283mono24k samples, SHA256 `c03e2da1cf1877fc829168840d894fb846716c69d80d4f00ae4cdaafea96a5c0`. It was used in full in both modes. The reference waveform and transcript are not distributed, so exact reproduction requires the same privately held inputs. Any other input is a different-reference experiment.

The primary run uses80ms/character, three seeds. A secondary run uses40ms/character and seed42 only, to distinguish conditioning delay from text starvation. Actual append timestamps are logged; Python scheduling makes actual text completion slightly later than nominal duration. Full controls use seed42. Warmup per mode uses seed0 and is excluded. Do not average full controls and character runs.

Model/revision and all dependencies are fixed in `bench.py` and `uv.lock`. The model is nonquantized Base1.7B bf16. `live.py` is a causal input adapter, not stock mlx-audio's full-input nonICL generation. Speaker-only starts with the complete reference's speaker embedding, first target token over codecBOS, then feeds subsequent target rows with generated codec. Only ICL primes the decoder with reference codes. Neither mode truncates the reference. Layout was checked against Qwen's causal x-vector-only structure; a new cross-framework numerical-parity fixture was not run.

`evaluate.py` runs independent ECAPA-TDNN ONNX on mono16k float waveforms and a fixed Whisper large-v3-turbo for reading diagnostics. ECAPA: `pranjal-pravesh/ecapa_tdnn_onnx` revision04c3ffe4fd00b3b7853fd57db44e2e531d4817f2, SHA256245eb5995cfffd74494862dee33da2b00c1c2579eb0c6703847784e9901ed458. It takes raw waveform and returns192dimensions. Cache default can be overridden by `--ecapa`; if the file is absent, the fixed Hugging Face revision is downloaded and its SHA256 is checked. Qwen's own encoder cosine is supplementary; it favors the very embedding used for conditioning. Whisper hash-identical PCM is evaluated once and reused. NFKC/lowercase/punctuation/symbol/whitespace removal precedes character edit distance; kanji/kana spelling differences can count as errors.

## Timing and listening limits

- First PCM is the arrival of a four-frame chunk, roughly320ms of audio. It may contain silence.
- `audit.py` reports simulated first voiced playout: first10ms RMS>.003, honoring measured chunk arrivals and earlier queued samples. It excludes device/network latency and is not a microphone measurement.
- `gap_s` is the sum of gaps if playback starts at first PCM with no extra buffer. It is caused by input availability as well as generation. `replay.py` inserts the measured initial wait and gaps without stretching or changing original audio.
- `*-listen.wav` is unmodified concatenated speech converted toPCM16, for comparing the generated voice/prosody. `*-arrival.wav` is delivery replay, for comparing startup and stalls. Do not judge streaming continuity from concatenated WAV alone.
- No human listening scores have been assigned. ASR and speaker cosine do not establish Japanese naturalness, perceived identity, or a user preference. `listening.csv` leaves ratings blank.

## Results (2026-10-22)

**同じ10.678秒の参照を維持して、話者埋め込みだけで入力完了前の生成を開始できた。ただし独立encoderの話者類似度は下がり、遅い文字入力では再生待ちが生じた。置き換えて同等品質とはまだ判断しない。**

Apple M4 Max128GB、macOS27.0.1、Python3.12.11、MLX0.32.4、mlx-audio0.6.1、transformers5.20.2、numpy2.5.4。通常サービスを止めない別processで実行。開始前のサービスqueueは0だが、GPUを占有した隔離測定ではない。ネットワーク・Spirits Garden・実LLM・speaker再生は測定外。参照や本番コード・設定は変更していない。

### 最初の音声

主比較: 80ms/文字、45文字の短文と125文字の長文、各seed42/43/44。値は3試行の中央値（範囲）。「発声開始」は到着時刻を守り、10msRMS>.003となる最初の音を再生できる時刻のシミュレーション。デバイス遅延は含めない。

| 条件 | 現方式ICL: 初回PCM | 話者埋め込みのみ: 初回PCM | ICL: 発声開始推定 | 埋め込みのみ: 発声開始推定 |
|---|---:|---:|---:|---:|
| 短文80ms/文字 |4.246秒(4.206–4.248)|1.488秒(1.486–1.509)|4.938秒(4.806–5.176)|2.302秒(1.566–2.311)|
| 長文80ms/文字 |11.156秒(11.143–11.161)|2.471秒(2.456–2.502)|11.973秒(11.871–12.166)|2.736秒(2.551–2.882)|

- 初期本文条件はICL105token、埋め込みのみ1token。埋め込みのみは6/6でtext.done前にPCM、ICLは6/6でtext.done後。入力完了は短文約3.9秒、長文約10.8–10.9秒。
- ただし1token条件でも1文字から必ず鳴るわけではない。最後の日本語pre-tokenを境界まで待ち、さらに4codec frameを作る本文も必要。今回の初回PCMは短文18文字、長文29文字時点が中心だった。
- すぐ再生する場合、埋め込みのみは短文1.51–1.54秒、長文2.88–2.97秒の累積途切れを予測。ICLは本文を待ち終えてから始めるため0。早期開始と連続再生は別問題。

速めの入力40ms/文字、seed42の追加確認（各1試行）:

| 条件 | ICL: PCM / 発声開始推定 | 埋め込みのみ: PCM / 発声開始推定 | 埋め込みのみの累積途切れ |
|---|---:|---:|---:|
| 短文 |2.443 / 3.133秒|0.852 / 0.932秒|0.412秒|
| 長文 |6.198 / 6.908秒|1.423 / 1.703秒|0秒|

この追加試行も埋め込みのみは入力終了前に音声が出た。GPT-Liveのcaption間隔そのものを再現した試行ではなく、速さを2条件で変えた比較。

全文入力・準備済みseed42controlの初回PCM: ICL短文0.286秒/長文0.280秒、埋め込みのみ短文0.095秒/長文0.095秒。プロセスのモデルloadは13.05秒、参照準備はICL0.852秒/埋め込みのみ0.028秒。準備済み表にこれらは入れない。各modeのseed0 warmupは比較から除外した。cold startの保証ではない。

### 声の似方

独立ECAPA-TDNNで、全参照対全生成音声のcosine。80ms/文字の6音声/方式。参照自己cos≈1を確認した。

| 方式 | 平均 | 範囲 |
|---|---:|---:|
| 現方式ICL |0.747|0.716–0.771|
| 話者埋め込みのみ |0.654|0.621–0.693|

同じ文・seedの6組すべてでICLの値が高い。これは「似方を完全に保てた」という仮説に不利な結果。ただし尺度の1点を人の好みや認識率へ換算はできない。日本語・合成音声へのencoderの偏りもあり、人の聴感評価は未実施。

Qwen自身のspeaker encoderではICL約0.98、埋め込みのみ約0.97–0.98と両方高かった。conditioningと同じencoderだけでは差を小さく見積もりうるため、採否には独立指標を主に示す。

### 日本語・自然さ

- 20計測発話すべてEOSで終了、有限PCM、clipped sample0。これとは別にwarmup4発話を保存。
- 80ms/文字の短文は両方式3/3で正規化ASR CER0。長文はICL0–1.74%、埋め込みのみ0–1.74%。「おいしい」対「美味しい」の表記差が1.74%になる例と、ICLの1例でASRが冒頭「うん」を認識しない例がある。大きな読み崩れや全文の繰り返しは、このASR出力では見つからなかった。
- これは抑揚・間・声の自然さが同等という結論ではない。連結音声と到着再現の両方を聴き比べる必要がある。とくに80ms/文字の埋め込みのみには上記の待ちがある。
- seed42の全文controlと80ms/文字はICLの2文と埋め込みのみの長文でPCM hashが一致。埋め込みのみの短文では一致しなかった。open中のEOS抑制など生成時の条件が違うため、入力スケジュールに対する普遍的な波形一致は主張しない。

### 判断と未確認

速度面は有望で、同じ参照のまま通話用の選択肢にする根拠は得られた。一方、話者指標の低下と入力待ちがあり、現方式を無条件に置き換える根拠にはならない。次に人が2方式の声と日本語の抑揚を聴き、実captionの供給と小さい再生bufferを合わせて評価する。実マイク/AEC・自然な会話・別話者・他言語・量子化モデルは未検証。

本番kiapi/Spirits Gardenには反映していない。

Evidence: [80ms results](results/80ms/results.json), [independent/ASR scores](results/80ms/evaluation.json), [40ms results](results/40ms/results.json), [environment](results/80ms/environment.json). Audio remains in ignored `output/` and `output-fast/`; listening files and arrival replays are generated by the scripts. Private reference and generated clone audio are not published in Git.

