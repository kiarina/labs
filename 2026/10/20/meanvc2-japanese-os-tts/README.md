# MeanVC2 voice conversion on Japanese OS text-to-speech

macOS の音声合成（`say`）で作った日本語の声を、[MeanVC2](https://github.com/ASLP-lab/MeanVC2) の
zero-shot voice conversion で参照の声に変え、質と日本語での使いやすさを確かめます。
参照の声をアップロード（またはマイクで録音）し、OS の声（または録音した人の声）を変換して聞き比べる Web UI を持ちます。

前の lab [MeanVC streaming zero-shot voice conversion on Apple Silicon](../../../07/19/meanvc-streaming-apple-silicon/README.md)
は初代 MeanVC をマイクの経路で測りました。この lab は後継の MeanVC2 を、アプリが自分で鳴らす
TTS の声（Spirit ごとに声を持たせる用途）に当てます。

## Purpose

明らかにしたい問いは次のとおりです。

- OS の日本語の TTS の声を MeanVC2 で変換したとき、聞いて自然か、参照の声らしくなるか
- 日本語の発音（促音・長音・カタカナ語・数字）が崩れずに残るか
- 1 文の変換に、手元の CPU でどれだけ時間がかかるか
- OS の声によって結果が変わるか

評価は、まず人が Web UI で聞いて判断します。補助として、変換の前後を同じ ASR で文字にして比べ、
変換の時間を測ります。流しながらの変換、ONNX への書き出し、Windows はこの lab の範囲外です。

## Run

macOS（Apple Silicon）、Python 3.11、[uv](https://docs.astral.sh/uv/)、[mise](https://mise.jdx.dev/) が要ります。

```sh
mise -C 2026/10/20/meanvc2-japanese-os-tts run
```

初回は MeanVC2 のコードと checkpoint、WavLM-Large、s3prl のコードを `vendor/` に取ります（約 1.5 GB）。
モデルを読み込んだ後、`http://127.0.0.1:8775/` を開きます。

1. **参照の声**: ファイルをドロップするか、マイクで録る。共有の会話の素材の 2 人の話者も最初から選べる
2. **元の声**: OS の声と文を選ぶ（文の例のボタンあり）。「録音・ファイル」では、マイクで録った声や音声ファイルを元の声にできる（人の声との比較用）
3. **変換**: モデル（`120ms` は質を優先、`40ms` は遅れを優先）と steps を選び、「変換する」。
   「日本語の声をすべて」は、`ja_JP` の声を順に同じ文で変換する

結果は元の声と変換後を並べて再生でき、変換の時間、長さ、ピークを表示します。
生成した音声は `output/webui/` に残ります（Git の対象外）。

## Components

| Part | Source | Revision / SHA-256 |
|---|---|---|
| MeanVC2 code | `ASLP-lab/MeanVC2` | `13acf84c1bf135ea5edad9c245b345289b06b33e` |
| MeanVC2 checkpoints | Hugging Face `ASLP-lab/MeanVC2` | `39cdd19522fe896c227da691314d9a0e3b995486` |
| Speaker encoder (ECAPA-TDNN on WavLM) | Google Drive id in upstream `initialization.py` | `51f07e3b…fe7f94b` |
| WavLM-Large | Hugging Face `s3prl/converted_ckpts` | `8cad0b370e7e35f8d56951d95d2be036ea85510c` |
| s3prl code | `s3prl/s3prl` | `ec8064b5889f81ca460fbe2c094ce576a6f120b7` |

各ファイルの SHA-256 は `meanvc2_runtime.py` で検証します。MeanVC2 のコードと checkpoint は Apache-2.0 です。

変換は upstream の `src/infer/infer_e2e.py`（ファイル丸ごとの変換）と同じ処理です。

- 元の声から Fast-U2++ の bottleneck feature（`120ms` は 160 ms の ASR、`40ms` は 80 ms の ASR）
- 参照の声から WavLM + ECAPA-TDNN の話者埋め込み（256 次元）。MeanVC2 は参照の mel を使わない
- mean flow の DiT（KV cache 付きの chunk 処理）と Vocos で 16 kHz の波形に戻す

upstream から変えた点は次のとおりです。upstream のソースそのものは変更しません。

- WavLM-Large を可変の release URL でなく、版を固定した s3prl の変換済み checkpoint から取る
- `src/model/__init__.py` が学習用の依存（accelerate、wandb、ema-pytorch）を import するので、
  推論で使う module だけを読むよう、`src`・`src.model` を空の package として登録する
- upstream の `load_checkpoint`（EMA の safetensors を読む）と同じ処理を lab 側で行う。CUDA のときの half への変換は CPU では通らないので持たない

torch は upstream の `requirements.txt` と同じ `2.5.1` に固定します。torchaudio の新しい版では
`torchaudio.compliance.kaldi` などの API が整理されつつあり、前の lab では新しい版の import で
upstream が壊れました。新しい版へ上げるのは、同じ入力で出力が一致すると示せたときにします。

## Conditions

- MacBook Pro、Apple M1 Max、macOS 27、CPU、torch のスレッド 4
- 乱数の seed は変換ごとに 0
- TTS: `say -v <voice> -o out.wav --file-format=WAVE --data-format=LEI16@16000`（16 kHz mono）
- 共有の素材: `tests/assets/mp3/conversation_2speaker_14s_16k.mp3`。前の lab と同じ発話の境界で 2 人に分ける

## Observed results (2026-10-20, first run)

Web UI の動作、時間・ASR による補助の観測と、1 人の聞き手（lab の作者）の聴取の結果です。

### Listening (2026-10-20, one listener)

Web UI で、OS の声と、聞き手が自分で録った声を元にして、参照の声へ変換して聞きました。
参照には、サンプルの話者と聞き手がアップロード・録音した声を使いました。聞いた文と組み合わせの数は記録していません。

- 日本語でも十分に使えそうだった
- 出力の質は元の声に強く依存した。OS の TTS は機械的な話し方で、変換後もそれが抜けずに違和感が残った
- 聞き手が自分で録った声を元にすると、変換後の違和感は小さかった

解釈: MeanVC2 が変えるのは主に声の質で、抑揚・リズム・間は元の声のものが残ります。TTS の声に使うときの
質の上限は、元にする TTS の話し方で決まりそうです。声ごとの違い（下の ASR の表）を聞き分けた記録はありません。

### Processing time

文「こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？」、
Kyoko で 7.86 秒、参照はサンプルの話者 1（6.6 秒）。

| Measurement | Value |
|---|---:|
| model load（話者の encoder と Vocos） | 約 6 秒（プロセスの起動を含めて約 17 秒） |
| 参照の話者埋め込み | 0.39〜0.44 秒（参照ごとに 1 回） |
| `120ms` の変換（特徴 + DiT + Vocos） | 2.1〜2.4 秒（元の長さの 0.26〜0.31 倍） |
| `40ms` の変換 | 約 5.4 秒（元の長さの約 0.69 倍） |
| `say` の合成 | 約 1.9 秒（初回） |

`40ms` は chunk が小さく、ファイル丸ごとの変換では `120ms` より約 2.5 倍遅くなりました。
この lab の用途（1 文ずつまとめて変換）では、`120ms` を既定にしています。

### Japanese intelligibility (ASR proxy)

同じ文を 9 個の `ja_JP` の声で読ませ、参照をサンプルの話者 1 にして `120ms`・steps 3 で変換しました。
変換の前後を whisper.cpp（`ggml-medium`、`-l ja`）で文字にしました。

| OS voice | Converted transcript |
|---|---|
| Kyoko（2 回） | こんにちは。今日は良い天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか? |
| Eddy | 本日は、今日は良い年ですね。少し散歩してから、駅前のタペで講習読みませんな。 |
| Flo | こんにちは。今日は良いエニフィですね。少し散歩してから、駅前へのタペでコーシーを飲みました。 |
| Grandma | こんにちは。今日は良い天気ですね。少し散歩してから駅前への旅でご修行のみません。 |
| Grandpa | こんにちは。今日はいえにいいですね。少し散歩してから、駅前の壁で合衆読みませんか? |
| Reed | こんにちは。今日はいいえん日ですね。少し散歩してから、駅前のカフェでご修行を見ませんか? |
| Rocko | こんにちはようはいらないですね少し散歩してから駅前のカフェで帽子を乗りませんか |
| Sandy | こんにちは。今日ははいいで、いいですね。少し散歩してから、今へのタフェネコーシーを飲みましょうか。 |
| Shelley | こんにちは。今日は良い年にですね。少し散歩しちゃうから駅前のタペでこーしーを飲みませんな。 |

変換前は 9 個の声すべてで正しく文字になりました（句読点の有無だけが違う）。変換後に正しく残ったのは
Kyoko だけで、ほかの 8 個は「天気」「カフェ」「コーヒー」が崩れました。

解釈（未確認）: Kyoko とほかの声では、合成の方式や声の高さ・話す速さが違います。MeanVC2 の内容の
特徴を作る Fast-U2++ は中国語が中心の学習なので、学習の分布から遠い声ほど内容が崩れる可能性があります。
ただし、文 1 つ・参照 1 つ・ASR 1 つの観測で、聞いた印象とは別です。ASR の誤りは聞き取りにくさの
目安であって、人が聞いて崩れていると感じるかは確かめていません。

## Limitations and next steps

- 聴取は 1 人で、文・組み合わせを記録していない。声ごとの違いを聞き分けるなら、条件を決めて記録する
- 自然な話し方の TTS（クラウドの TTS、zero-shot の TTS など）を元にしたときの質。元の声の話し方が質を決めるという解釈を確かめる
- 続き: 声の変換をせず、参照の声で最初から話す zero-shot の TTS を比べた lab は [CosyVoice 3 and Qwen3-TTS zero-shot voice cloning in Japanese](../japanese-zero-shot-tts-compare/README.md)（Qwen3-TTS の MLX bf16 が速さと質の両方で使えると分かった）
- 文・参照の声・OS の声を増やし、文字の誤り率（CER）としてまとめる
- 話者の近さを、MeanVC2 の encoder とは別の埋め込み（前の lab の ECAPA の ONNX など）で測る
- 人の日本語の声を元にした変換と比べ、TTS 特有の問題かを分ける
- 参照の長さ、steps、`40ms` のモデルでの違い
- 流しながらの変換、ONNX への書き出し、Windows は、質の判断の後に別の lab で扱う
  （流しながらの変換と Windows は [gpt-live-1-codex の受信音への組み込み](../flutter-gpt-live-codex-meanvc2-playout/README.md) で確かめた。ONNX は未着手）
