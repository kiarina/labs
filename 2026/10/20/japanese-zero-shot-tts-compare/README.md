# CosyVoice 3 and Qwen3-TTS zero-shot voice cloning in Japanese

参照の声を数秒〜十数秒与えて、その声で日本語の文を読ませる zero-shot の TTS を 2 つ比べます。
[CosyVoice 3](https://github.com/FunAudioLLM/CosyVoice)（Fun-CosyVoice3-0.5B-2512）と
[Qwen3-TTS](https://github.com/QwenLM/Qwen3-TTS)（12Hz Base）に同じ参照・同じ文を渡し、
Web UI で並べて聞きます。

前の lab [MeanVC2 voice conversion on Japanese OS text-to-speech](../meanvc2-japanese-os-tts/README.md) では、
OS の TTS の声を MeanVC2 で変換すると、声の質は変わるが話し方（抑揚・リズム）は元の TTS のまま残り、
機械っぽさが抜けないと分かりました。この lab は、最初から参照の声で自然に話す TTS がその代わりになるかを確かめます。

## Purpose

- 参照の声らしさと話し方の自然さで、どちらが日本語に向くか（人が聞いて判断する）
- 日本語の読み（促音・長音・数字・英語混じり）が崩れないか
- 手元の Mac（Apple Silicon）でどれだけ時間がかかるか
- 参照の文字起こしの有無で、結果がどう変わるか

評価は、まず人が Web UI で聞いて判断します。補助として、生成した音声を ASR で文字にし、時間を測ります。

## Run

macOS（Apple Silicon）、[uv](https://docs.astral.sh/uv/)、[mise](https://mise.jdx.dev/) が要ります。

```sh
mise -C 2026/10/20/japanese-zero-shot-tts-compare run
```

初回は、CosyVoice のコード（Matcha-TTS を含む）、各モデル（MLX の 3 つの量子化を含む）、Whisper を取ります（合わせて約 20 GB）。
`http://127.0.0.1:8776/` を開き、画面の上で 3 つの worker が「準備完了」になるのを待ちます。MLX の worker は 3 つの量子化を全部読み込みます（約 10 GB）。

1. **参照の声**: ファイルをドロップするか、マイクで録る。追加すると Whisper が自動で文字起こしする。
   違っていたら欄を直す（次の生成から使う）。共有の会話の素材の 2 人の話者も最初から選べる
2. **読ませる文**: 文を入れる（文の例のボタンあり）。CosyVoice 3 に渡すカタカナが下に出る
3. **比べる列**を選ぶ: Qwen3-TTS PyTorch、CosyVoice 3、Qwen3-TTS MLX の fp32・bf16・8bit・4bit（既定は CosyVoice 3 以外）。
   MLX の fp32 は、mlx-community の bf16 の重みを float32 に変えて float32 で計算する（元の PyTorch の重みも同じ bf16 の値なので、重みの情報は失わない）
4. **読ませる**: 結果に参照の声と選んだ列を並べる。「文の例をすべて」は例の 7 文を順に生成する。
   上の「時間のまとめ」に、列ごとの生成時間・倍率（生成時間 ÷ 音声の長さ）・最初の音までの時間・途切れの平均を出す

オプション:

- 「参照の声の文字起こしを渡す」を外すと、声だけでまねる（Qwen3-TTS は x-vector だけ、CosyVoice 3 は cross-lingual）
- 「CosyVoice 3 にはカタカナにして渡す」を外すと、漢字かな交じりのまま渡す
- 「MLX はストリーミングで生成する」: mlx-audio の `stream=True` でチャンクごとに受け取り、届いた時刻を測る。チャンクの長さ（`streaming_interval`）は 0.25〜2 秒。
  最初のチャンクが届いた時に再生を始め、チャンクを続けて鳴らしたとすると何秒途切れるか（途切れ）も出す。結果の帯は、各チャンクの届いた時刻と長さ。
  保存する音声はチャンクをつないだもの（つなぎ目も聞ける）。ブラウザへのストリーミング再生はしない
- 「MLX を PyTorch 版と同じ生成の設定にする」（既定でオン）: mlx-audio の声のクローンの設定を qwen-tts に合わせる（下の「MLX vs PyTorch, stage by stage」）。外すと mlx-audio の既定
- 「話し始めの補正」: ストリーミングのときに、復号器を参照の声の符号で温めてから始める（下の「Streaming onset」）。既定は参照の末尾 1 秒
- 「1 列ずつ順に動かす」（既定）: 外すと worker ごとに同時に動かす（GPU・CPU を取り合うので時間は正しくない）
- Qwen3-TTS PyTorch のモデル（1.7B・0.6B）と seed

生成した音声は `output/webui/` に残ります（Git の対象外）。

## Structure

エンジンは依存がぶつかる（CosyVoice は torch 2.3.1・transformers 4.51.3、Qwen3-TTS は transformers 4.57.3）ので、
それぞれ `engines/<name>/` に別の Python 環境と worker を持ちます。

- `server.py`（Python 3.12）: Web UI、参照の声の変換（`afconvert` で 24 kHz mono）、Whisper の文字起こし、カタカナへの変換。
  worker を子プロセスとして起動し、stdin へ JSON の要求を送り、別のパイプ（`WORKER_REPLY_FD`）で返事を受ける
  （ライブラリが stdout に書くので、返事と分ける）
- `engines/qwen3_tts/worker.py`（Python 3.12、torch 2.14.1、`qwen-tts` 0.1.1）
- `engines/cosyvoice3/worker.py`（Python 3.11、upstream の `requirements.txt` のうち推論に要るものを同じ版で）
- `engines/qwen3_tts_mlx/worker.py`（Python 3.12、mlx 0.32.4、`mlx-audio` 0.6.0。バッファのキャッシュは 1 GB まで）
- `bench/qwen3_tts_mlx/bench.py`: MLX 版の速さとメモリを、Web UI を使わずに測る
- `bench/qwen3_tts_parity/`: MLX 版と PyTorch 版を段ごとに比べる（下の「MLX vs PyTorch, stage by stage」）

## Components

| Part | Source | Revision |
|---|---|---|
| Qwen3-TTS 1.7B Base | Hugging Face `Qwen/Qwen3-TTS-12Hz-1.7B-Base` | `fd4b254389122332181a7c3db7f27e918eec64e3` |
| Qwen3-TTS 0.6B Base | Hugging Face `Qwen/Qwen3-TTS-12Hz-0.6B-Base` | `5d83992436eae1d760afd27aff78a71d676296fc` |
| Qwen3-TTS code | PyPI `qwen-tts` | `0.1.1` |
| CosyVoice code | `FunAudioLLM/CosyVoice` | `074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc` |
| Matcha-TTS（CosyVoice の submodule） | `shivammehta25/Matcha-TTS` | `dd9105b34bf2be2230f4aa1e4769fb586a3c824e` |
| CosyVoice 3 model | Hugging Face `FunAudioLLM/Fun-CosyVoice3-0.5B-2512` | `29e01c4e8d000f4bcd70751be16fa94bf3d85a18` |
| Whisper（参照の文字起こし） | Hugging Face `mlx-community/whisper-large-v3-turbo`（`mlx-whisper` 0.4.3） | `a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb` |
| カタカナ | `fugashi` 1.5.2 + `unidic-lite` 1.0.8 | |

コードとモデルはどれも Apache-2.0 です（Qwen3-TTS・CosyVoice のリポジトリの LICENSE と、各モデルカードの `license`）。
Hugging Face にある CosyVoice 3 の日本語の追加学習の重み（`tts-dataset/cosyvoice3-ja-delta`）は研究用途だけの条件付きなので、使っていません。

CosyVoice のモデルのうち、RL 版の LLM（`llm.rl.pt`）、TensorRT 用、バッチ用の ONNX、デモの音声は取りません。
upstream の `AutoModel` は `llm.pt`（base）を読みます。

### Japanese input for CosyVoice 3

upstream の `example.py` は、日本語は漢字かな交じりでなくカタカナで渡すよう書いています
（`NOTE for Japanese usage, you must translate it to katakana.`、単語の間に空白、助詞の「は」は「ワ」）。
この lab は UniDic の発音（`pron`）を単語ごとに空白でつないで同じ形を作り、参照の文字起こしも同じく変換して渡します。
UniDic に発音の無い語（数字や英字など）は、表記のまま残ります。

### Deviations and pins

- CosyVoice の環境は upstream と同じ torch 2.3.1 だが、Python は 3.11 にした。3.10 で入る最新の scipy（1.15.3）の
  wheel が macOS 27 の dyld で読めない（`__DATA/__thread_bss` の zero-fill section）ので、scipy 1.17.1 を使える 3.11 にした
- upstream の `openai-whisper==20231117` は `pkg_resources` が無いとビルドできないので、20250625 にした（CosyVoice は log-mel の計算だけに使う）
- 推論で import される `hydra-core`・`rich`・`rootutils`・`pyarrow` などを足した（`pyproject.toml`）
- CosyVoice は upstream の作りで CUDA か CPU を選ぶ。MPS に移すと HiFT の float64 のテンソルで失敗したので、CPU で動かす
- torch 2.3.1・transformers 4.51.3 は upstream の固定に合わせた。新しい版へ上げるのは、同じ入力で出力が一致すると示せたときにする

## Conditions

- MacBook Pro、Apple M1 Max、macOS 27.0.1
- Qwen3-TTS: MPS、bfloat16、`attn_implementation="sdpa"`（flash-attn は無い）
- CosyVoice 3: CPU、float32、`stream=False`
- 乱数の seed は生成ごとに 0（UI で変えられる）
- 参照の声は 24 kHz mono に変換して両方に同じファイルを渡す
- 共有の素材: `tests/assets/mp3/conversation_2speaker_14s_16k.mp3`（前の lab と同じ発話の境界で 2 人に分ける。話者 1 の文字起こしは既知）

## Observed results (2026-10-20, first run)

### Listening (2026-10-20, one listener)

Web UI で聞いた lab の作者の評価: **Qwen3-TTS のほうが質が高い**。聞いた参照・文・組み合わせの数は記録していません。

Qwen3-TTS の PyTorch 版と MLX 版の比較（同じ人の評価）: **PyTorch が常に最も良い。PyTorch ≫ MLX bf16 > MLX 8bit ≒ MLX 4bit**。

同じ重み（1.7B Base）で、生成の設定（temperature 0.9・top_k 50・top_p 1.0・repetition penalty 1.05、sub-talker も 0.9・50）も同じでした
（`generation_config.json` と mlx-audio 0.6.0・qwen-tts 0.1.1 のコード）。参照の声の符号と話者の埋め込み（x-vector）も両方が使っています。
段ごとに比べた結果は下の「MLX vs PyTorch, stage by stage」にあります。各部品は一致し、違いは mlx-audio の生成の設定（繰り返しの罰則と、文と参照の符号の並べ方）でした。
上の評価は、その設定を PyTorch に合わせる前（mlx-audio の既定）の音です。

### Device and speed (before the web UI, one engine at a time)

文「こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？」、参照はサンプルの話者 1（6.6 秒、文字起こしあり）。
同じ条件で 2 回生成し、2 回目の値です。

| Engine | Device | Generate | Audio |
|---|---|---:|---:|
| Qwen3-TTS 0.6B | MPS bfloat16 | 9.1 秒 | 6.1 秒 |
| Qwen3-TTS 0.6B | MPS float32 | 10.3 秒 | 7.0 秒 |
| Qwen3-TTS 0.6B | CPU float32 | 26.3 秒 | 6.5 秒 |
| Qwen3-TTS 1.7B | MPS bfloat16 | 9.7 秒 | 6.3 秒 |
| CosyVoice 3（カタカナ） | CPU float32 | 23.1 秒 | 6.7 秒 |

MPS では 1.7B と 0.6B がほぼ同じ速さでした（1 歩ずつの生成の手間が支配的と推測）。そこで Qwen3-TTS は 1.7B・MPS・bfloat16 を既定にしました。
どちらも実時間より遅く（音声の長さの 1.5〜3.5 倍）、この Mac では会話の応答にそのまま使える速さではありません。

### Web UI (both engines at the same time)

2 つを同時に動かすと、初回の文で Qwen3-TTS 22.9 秒・CosyVoice 3 27.9 秒（合わせて 29 秒）。
続く 4 秒ほどの文では、Qwen3-TTS 9〜10 秒、CosyVoice 3 17〜19 秒でした。同じ Mac で前の lab の Web UI も動いていた時の値です。

### Japanese text for CosyVoice 3

参照・文は上と同じ。CPU で、カタカナと漢字かな交じりを比べ、whisper.cpp（`ggml-medium`、`-l ja`）で文字にしました。

| Input | Transcript |
|---|---|
| カタカナ | こんにちは。今日は良い天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか? |
| 漢字かな交じり | ミンチ、コウは、いい、元気ですね。ケイティオウは、いい、天気ですね。マル、サクシー散歩してから、気前のカフェでコーキーを飲みませんか? |

漢字かな交じりのままでは読みが崩れ、音声も 9.6 秒に伸びました（カタカナは 6.7 秒）。upstream の指示どおり、カタカナにする必要があります。

### Intelligibility (ASR proxy)

Web UI で作った 3 組（2 文、文字起こしあり・なし）を同じく whisper.cpp で文字にしました。6 つとも文のとおりに文字になりました（句読点の有無だけが違う）。

| Text | Reference transcript | Qwen3-TTS | CosyVoice 3 |
|---|---|---|---|
| 挨拶の文 | あり | 正しい | 正しい |
| 促音・長音の文 | あり | 正しい | 正しい |
| 促音・長音の文 | なし | 正しい | 正しい |

文 2 つ・参照 1 つの観測です。ASR が正しく読めることは、話し方の自然さや参照の声らしさとは別です。

### Memory (PyTorch, the web UI's workers)

両方の worker が 1 文以上生成した後、`footprint -p` で測りました（Qwen3-TTS は 1.7B だけを読み込んだ状態）。

| Worker | phys_footprint | Peak | 内訳 |
|---|---:|---:|---|
| Qwen3-TTS 1.7B（MPS bf16） | 6.95 GB | 7.02 GB | GPU（IOAccelerator）6.0 GB、プロセスの RSS 1.2 GB |
| CosyVoice 3（CPU fp32） | 7.35 GB | 8.78 GB | ほぼ RSS |

PyTorch の MPS は解放したメモリをキャッシュとして持つので、6.0 GB は実際に要る量より多い可能性があります（未確認）。

### Qwen3-TTS on MLX

[mlx-audio](https://github.com/Blaizzy/mlx-audio) 0.6.0 が Qwen3-TTS の Base（`ref_audio` + `ref_text` での声のクローン）に対応し、
mlx-community が bf16・8bit・4bit に変換したモデルを出しています（Apache-2.0）。`bench/qwen3_tts_mlx/bench.py` で、
上と同じ参照（サンプルの話者 1、24 kHz）と文を 3 回ずつ生成しました。MLX のバッファのキャッシュは 0 に制限しています（`--keep-cache` で外せる）。

```sh
cd 2026/10/20/japanese-zero-shot-tts-compare/bench/qwen3_tts_mlx
uv run python bench.py 8bit
```

| Model | Revision | Resident after load | Generate（2・3 回目） | Audio | Peak footprint |
|---|---|---:|---:|---:|---:|
| bf16 | `a6eb4f68e4b056f1215157bb696209bc82a6db48` | 4.57 GB | 4.0〜4.1 秒 | 7.6 秒 | 8.81 GB |
| 8bit | `e7dd0585652209fa0d7783659aad4e8a324de11c` | 3.20 GB | 2.7 秒 | 6.4 秒 | 7.32 GB |
| 4bit | `37e955a1deb861c088ae5f3a67043185f3d1a60c` | 2.46 GB | 2.6 秒 | 6.4 秒 | 6.58 GB |

- 同じ Mac の PyTorch（MPS bf16、約 10 秒）より 2.5〜4 倍速く、どれも実時間より速くなりました（音声の長さの 0.4〜0.55 倍）。1 回目は 4〜7 秒
- 生成の間だけ、どの量子化でも約 4.1 GB が上乗せされ、終わると読み込み直後の量に戻りました。どの処理が使うのか（参照の音声の符号化、音声への復号など）は切り分けていません
- 3 つとも whisper.cpp（`ggml-medium`）で文のとおりに文字になりました（句読点だけが違う）。量子化で声の質がどれだけ変わるかは聞いていません
- 計測は、同じ Mac で 2 つの Web UI（この lab と前の lab）を動かしたまま行いました

### Quantization and streaming in the web UI (7 sentences)

参照はサンプルの話者 1（文字起こしあり）、文は文の例の 7 つ（音声 2.6〜10.9 秒）。「1 列ずつ順に動かす」で、
Qwen3-TTS PyTorch（1.7B）と MLX の bf16・8bit・4bit を、ストリーミングなしとあり（チャンク 0.5 秒）で 1 回ずつ生成しました。
PyTorch はストリーミングの設定に関係なく同じ処理なので 14 回です。同じ Mac で前の lab の Web UI も動いていました。
この表のストリーミングは、下の「Streaming onset」の補正を入れる前（補正なし）の値です。

| Column | Runs | Generate (mean) | Audio (mean) | Ratio (mean, min–max) | First audio (mean, max) | Stalls |
|---|---:|---:|---:|---:|---:|---:|
| PyTorch 1.7B（MPS bf16） | 14 | 9.81 秒 | 5.61 秒 | 1.74（1.60–2.03） | — | — |
| MLX bf16 | 7 | 3.18 秒 | 5.87 秒 | 0.55（0.51–0.58） | — | — |
| MLX 8bit | 7 | 2.53 秒 | 5.93 秒 | 0.44（0.40–0.47） | — | — |
| MLX 4bit | 7 | 2.25 秒 | 5.70 秒 | 0.40（0.36–0.46） | — | — |
| MLX bf16 streaming 0.5 秒 | 7 | 3.13 秒 | 5.87 秒 | 0.54（0.50–0.63） | 0.40 秒、0.55 秒 | 0 |
| MLX 8bit streaming 0.5 秒 | 7 | 2.46 秒 | 5.93 秒 | 0.42（0.38–0.53） | 0.32 秒、0.33 秒 | 0 |
| MLX 4bit streaming 0.5 秒 | 7 | 2.11 秒 | 5.70 秒 | 0.37（0.34–0.48） | 0.30 秒、0.36 秒 | 0 |

倍率は生成時間 ÷ 音声の長さ（1 より小さいと実時間より速い）。最初の音は、生成を始めてから最初のチャンクが届くまで。
途切れは、最初のチャンクが届いた時に再生を始め、チャンクを続けて鳴らしたときに足りなくなる秒数です（Web UI が計算する。ブラウザで実際に流して鳴らしてはいない）。

- **ストリーミングで取得できた。** mlx-audio の `stream=True` で、0.48 秒ずつのチャンクが届き、最初の音は 0.3〜0.55 秒、7 文とも途切れは 0 でした
  （生成が実時間の 0.34〜0.63 倍の速さなので、後のチャンクほど余裕が増える）。ストリーミングにしても全体の生成時間はほぼ同じでした
- ストリーミングなしの場合、最初の音を出せるのは生成が終わった時（MLX で最大 3.8〜5.4 秒、PyTorch で約 10 秒）
- MLX の worker のメモリのピーク（`mx.get_peak_memory`、読み込んだ 3 つのモデル約 10.3 GB を含む）は、ストリーミングなしで 15.2〜15.3 GB、
  ストリーミングで 10.9 GB でした。生成中の上乗せは、ストリーミングなしで約 5 GB、ストリーミングで約 0.6 GB です（少しずつ音声に復号するためと推測）
- PyTorch 版（`qwen-tts` 0.1.1）は、生成のストリーミングの口がありません（`non_streaming_mode` は文字の入力を流す真似だけ、と upstream の説明にある）

whisper.cpp（`ggml-medium`）で、ストリーミングで作った 4bit・8bit の 14 本を文字にしました。13 本は文のとおり（句読点の違いだけ）でした。
「八重洲口」だけは 4bit が「八戸市口」、8bit が「八重杉地」になりました。同じ文を bf16 は「八重洲口」、PyTorch は 2 回とも「安口」でした。
固有名詞 1 つ・ASR 1 つの観測で、読みの誤りなのか ASR の誤りなのかは聞いて確かめていません。

### Streaming onset

聞いた lab の作者の評価: ストリーミングにすると、話し始めの声の調子だけ少し崩れる。

原因（コードと数値で確認）: mlx-audio 0.6.0 の声のクローン（`_generate_icl`）は、ストリーミングなしでは
`[参照の声の符号 + 生成した符号]` をまとめて復号し、参照の部分を切り落とします。ストリーミングでは復号器の状態を空にしてから、
生成した符号だけを 0.5 秒ずつ復号します。最初のチャンクは、前の文脈が無いまま復号されます。生成した符号（トークン）は同じです。

直し方: ストリーミングの復号器を空にした直後に、参照の声の符号を `streaming_step` に通して状態だけを残し（出力は捨てる）、
それから生成した符号を流します。`engines/qwen3_tts_mlx/worker.py` で、mlx-audio の
`Model._prepare_icl_generation_inputs`（参照の符号を受け取る）と `Qwen3TTSSpeechTokenizerDecoder.reset_streaming_state` を差し替えています。
Web UI の「話し始めの補正」で、なし・参照の末尾 1（既定）・2・4 秒・参照の全部を選べます。

`bench/streaming_onset/compare.py` で、7 文 × 3 つの量子化について、ストリーミングの最初の 0.5 秒をストリーミングなしの音と比べました（波形の相関。1 で同じ）。
長さが違う組（生成した符号が違う。8bit で 2 文、4bit で 1 文。ストリーミングなしでも同じ seed で符号が揺れる）は比べていません。

| Priming | bf16 corr (min / mean) | 8bit | 4bit | First audio (mean) |
|---|---|---|---|---:|
| なし | 0.141 / 0.533 | 0.153 / 0.711 | 0.614 / 0.873 | 0.35〜0.40 秒 |
| 末尾 12 符号（約 1 秒） | 0.886 / 0.948 | 0.900 / 0.949 | 0.709 / 0.930 | 0.41〜0.44 秒 |
| 末尾 25 符号（約 2 秒） | 0.925 / 0.962 | 0.905 / 0.958 | 0.810 / 0.950 | 0.45〜0.49 秒 |
| 末尾 50 符号（約 4 秒） | 0.783 / 0.956 | 0.896 / 0.972 | 0.975 / 0.990 | 0.54〜0.56 秒 |
| 参照の全部（6.6 秒） | 1.000 / 1.000 | 1.000 / 1.000 | 1.000 / 1.000 | 0.67〜0.69 秒 |

参照の全部で温めると、ストリーミングの音はストリーミングなしの音と同じになりました。その代わり、最初の音が約 0.3 秒遅れます
（参照の符号を復号する時間。参照が長いほど増える）。参照の全部を一度に復号するので、MLX の worker のメモリのピークも約 3 GB 上がりました（8bit の 1 文で 10.8 → 13.9 GB、3 モデル込み）。末尾だけでも大きく近づきますが、同じにはなりません。

聞いた lab の作者の評価: **参照の末尾 1 秒（12 符号）で OK**（話し始めの崩れが気にならない）。サンプルの話者 1 に加え、作者が自分で録った声を参照にしても同じでした。そこで Web UI の既定を末尾 1 秒にしました（最初の音は補正なしより約 0.05 秒遅いだけ）。聞いた文と回数は記録していません。
参照が同じなら温めた後の状態も同じなので、状態を取っておいて使い回せば、この遅れは無くせるはずです（未実装）。

### MLX vs PyTorch, stage by stage

聞いた評価で MLX が PyTorch に明らかに劣った原因を、段ごとに切り分けました。参照はサンプルの話者 1（6.6 秒、83 符号）と文字起こし、文は挨拶の文です。
[MLX 移植の一致検証の型](../../../../docs/mlx-port-parity.md)に従い、まず float32 で、各段に PyTorch 側と同じ入力を与えて比べました。
PyTorch 側は CPU float32（`torch_fixture.py`）。MLX 側は mlx-community の bf16 の重みを float32 に戻したもの（`mlx_compare.py --dtype float32`）で、
元の重みは両方とも同じ bf16 の値です（話し言葉の tokenizer の重みは両方とも float32）。

```sh
engines/qwen3_tts/.venv/bin/python bench/qwen3_tts_parity/torch_fixture.py --generate
engines/qwen3_tts_mlx/.venv/bin/python bench/qwen3_tts_parity/mlx_compare.py --dtype float32
```

| Stage | Compared | float32 | MLX bf16（実行時の設定） |
|---|---|---|---|
| 1 参照の声 | 読み込んだ波形（24 kHz のファイル。どちらも再サンプリングしない） | 差 0 | 差 0 |
| 1 参照の符号 | speech tokenizer の encode（同じ波形） | 83 中 82 が 16 個とも同じ。11 番目だけ 8〜16 個目の符号が違う | 同じ |
| 2 mel | 話者の埋め込みの mel | cos 1.000000（最大差 0.11、対数の小さい値） | 同じ |
| 2 x-vector | 同じ mel から | cos 1.000000（相対誤差 6.6e-7） | cos 0.999996 |
| 3 talker | 同じ入力の埋め込みでの 1 歩目の logits | KL 1.5e-10、最大差 3.8e-5 | KL 7.2e-4 |
| 3 code predictor | 同じ hidden と 1 フレームの符号で、15 段を teacher forcing | KL 2.2e-10、argmax 15/15 | KL 2.2e-3、argmax 15/15 |
| 4 復号 | 参照の 83 符号から音声へ | cos 0.99998、相対誤差 6.3e-3 | 同じ（復号器は float32 のまま） |

KL は temperature 0.9 の分布で、PyTorch を基準にした値です。**部品はどれも一致しました。** bf16 の差も、PyTorch 自身を MPS の bf16 で動かした差より小さく
（MPS bf16 と CPU float32 の 1 歩目の logits の KL は 4.7e-2）、MLX の bf16 の計算は原因ではありません。

違いは、mlx-audio 0.6.0 の声のクローンが、qwen-tts 0.1.1 の `generate_voice_clone` の既定と違う設定で生成していることでした（コードで確認）。

1. **繰り返しの罰則**: mlx-audio は声のクローンのときだけ `max(repetition_penalty, 1.5)` にし（`Model.generate`、コメントは「長い参照の prefill で符号が崩れるのを防ぐ」）、
   直近 64 個の符号に掛けます。qwen-tts は checkpoint の 1.05 を、生成したすべての符号に掛けます（transformers の `RepetitionPenaltyLogitsProcessor`）
2. **文と参照の符号の並べ方**: qwen-tts の既定（`non_streaming_mode=False`）は、文（参照の文字起こし + 読ませる文 + eos）を参照の符号に 1 つずつ重ね、
   余った文を生成の 1 歩ごとに足します。mlx-audio は常に `non_streaming_mode=True` の並べ方（文を全部 codec pad に重ね、その後に参照の符号を tts pad に重ねる）です。
   この参照と文では prefill が 151（mlx-audio）と 93（qwen-tts）で、同じ部品に入れた 1 歩目の logits の KL は 2.2e-2 でした

worker で両方を qwen-tts に合わせると（`match_pytorch`）、prefill の埋め込みは PyTorch と一致し（同じ参照の符号を与えて float32 で cos 1.000000）、
1 歩目の logits の KL は 1.8e-4（MLX 自身の参照の符号で）になりました。

生成した符号の統計（`mlx_generate.py`、`torch_generate.py`）。文 3 つ × seed 5、参照はサンプルの話者 1。PyTorch は Web UI の worker と同じ MPS bf16 です。

| Setting | Runs | 1 つ目の符号が前と同じ割合 | 異なる符号の割合 | 音声（平均） | 話者の cos（平均、最小） |
|---|---:|---:|---:|---:|---:|
| PyTorch MPS bf16 | 15 | 0.028 | 0.884 | 6.39 秒 | 0.977、0.966 |
| MLX bf16 mlx-audio の既定 | 15 | **0.000** | **0.970** | 6.86 秒 | 0.985、0.983 |
| MLX bf16 罰則だけ 1.05 | 15 | 0.020 | 0.892 | 6.96 秒 | 0.984、0.980 |
| MLX bf16 並べ方だけ | 15 | 0.000 | 0.975 | 6.78 秒 | 0.985、0.983 |
| MLX bf16 両方（`match_pytorch`） | 15 | 0.026 | 0.873 | 6.70 秒 | 0.985、0.983 |
| MLX 8bit mlx-audio の既定 | 15 | 0.000 | 0.975 | 6.93 秒 | 0.985、0.976 |
| MLX 8bit 両方（`match_pytorch`） | 15 | 0.023 | 0.886 | 7.06 秒 | 0.985、0.980 |

- **mlx-audio の罰則（1.5）のままだと、1 つ目の符号が直前と同じになることがほぼ無い**（bf16・8bit、並べ方の有無を合わせた 60 本のうち 59 本で一度も無い）。
  PyTorch は 15 本中 13 本で、約 3% のフレームが同じ符号を続けます（伸ばす音や間と推測）。
  罰則 1.5 が、直近 64 個（約 5 秒）に出た符号をほぼ使わせないためと考えます。罰則を 1.05 にすると、PyTorch と同じ統計に戻りました
- 話者の cos は、モデル自身の話者の埋め込み（float32）で、出力と参照を比べた値です。どの設定も 0.98 前後で、PyTorch が最も低く、聞いた評価とは合いません。
  この指標では質の差は測れませんでした（独立した話者の埋め込みは未確認）
- 長い文（昔話）では MLX が PyTorch より約 0.8 秒長いまま残りました（10.3 秒と 9.5 秒）。原因は確かめていません。
  違いとして残っているのは、PyTorch は参照の声を bf16 で符号にしていること（下）と、qwen-tts の `min_new_tokens=2`（最初の 2 歩は eos を出さない）を入れていないことです
- PyTorch の worker（MPS bf16）は speech tokenizer も bf16 で動かすので、参照の符号が float32 と違います（1 つ目の符号の一致 96%、16 個目は 5%）。
  MLX は speech tokenizer を float32 で動かし、float32 の PyTorch とほぼ同じ符号です。どちらが聞いて良いかは分けて聞いていません
- 速さは変わりません（Web UI で 3.5 秒の文が 2.0〜2.1 秒、ストリーミングの最初の音 0.37 秒）。上の「Qwen3-TTS on MLX」「Quantization and streaming」の表は合わせる前の値です

**聞いて確かめるのはこれから**です。Web UI の「MLX を PyTorch 版と同じ生成の設定にする」（既定でオン）を切り替えて、同じ seed で比べられます。

#### mlx-audio への報告の材料（未報告。報告はオーナーに確認してから）

- 対象: mlx-audio 0.6.0 の `mlx_audio/tts/models/qwen3_tts/qwen3_tts.py`。`Model.generate` の `icl_rep_penalty = max(repetition_penalty, 1.5)` と、
  `_prepare_icl_generation_inputs` が `non_streaming_mode=True` の並べ方だけを作ること
- 参照実装: qwen-tts 0.1.1 の `Qwen3TTSModel.generate_voice_clone`（`non_streaming_mode=False` が既定）と `Qwen3TTSForConditionalGeneration.generate_icl_prompt`
- 最小の再現: 上の 2 つのスクリプトで、部品は float32 で一致し（表）、1 つ目の符号が直前と同じになる割合が 0（PyTorch は 0.028）になることを示せる。
  `generate(..., repetition_penalty=1.05)` と明示しても 1.5 になる
- 直し方の案: 罰則は呼び出し側の値（checkpoint の既定 1.05）を使う。並べ方は qwen-tts と同じく文を参照の符号に重ねる形を既定にし、今の形は選べるようにする。
  worker の差し替え（`engines/qwen3_tts_mlx/worker.py`）がそのまま実装の例になる
- 付け加えて言えること: 罰則 1.5 の理由（長い参照で符号が崩れる）が、qwen-tts の並べ方でも起きるかは確かめていない。この lab の参照は 6.6 秒だけ
- コードを読んで気づいたが確かめていないこと: `Qwen3TTSSpeechTokenizer.decode` は有効な長さを「1 つ目の符号が 0 より大きいフレームの数」で数える。符号 0 は有効な値なので、
  生成に 0 が出ると末尾が切れる可能性がある

### MLX fp32

Web UI に MLX の fp32 の列を足しました（`engines/qwen3_tts_mlx/worker.py`）。mlx-audio の `load_model` は音声への復号器を `mx.compile` し、
compile した後は重みを変えられないので、compile を止めて読み込み、重みを float32 に変えてから復号器を compile します
（`bench/qwen3_tts_parity/mlx_compare.py` と同じ読み込み方。上の補正もそのまま効く）。

同じ参照（サンプルの話者 1）と挨拶の文、1 列ずつ順に。2 回目以降の値です。

| Column | Generate | Audio | Ratio | First audio（streaming 0.5 秒・末尾 1 秒の補正） |
|---|---:|---:|---:|---:|
| MLX fp32 | 4.6 秒 | 6.4 秒 | 0.71 | 0.52〜0.54 秒 |
| MLX bf16 | 3.2 秒 | 6.2 秒 | 0.51〜0.53 | 0.37 秒 |

fp32 も実時間より速いままでした。4 つのモデル（fp32・bf16・8bit・4bit）を読み込んだ MLX の worker は `phys_footprint` 18 GB（ピーク 23 GB）で、
3 つだった時（約 10 GB）から、fp32 の分が約 8 GB 増えました。whisper.cpp で文のとおりに文字になりました。fp32 と bf16 の聞き比べはまだです。

### CosyVoice 3 text normalization

CosyVoice 3 の worker は起動のたびに ModelScope から `pengzhendong/wetext` を取ろうとして 403 になり、`no frontend is avaliable` と出して
文の正規化（数字の読みなど）なしで動いていました。この lab の CosyVoice 3 の結果は、正規化なしの値です。

## Limitations and next steps

- 聞き比べは 1 人で、組み合わせを記録していない
- `match_pytorch` で MLX が PyTorch に追いついたかを聞いて確かめる。残る違い（長い文の長さ、参照の符号の bf16、`min_new_tokens`）を詰めるかはその結果で決める
- mlx-audio へ報告するか（上の「報告の材料」）をオーナーと決める
- 温めた後の復号器の状態を参照ごとに取っておき、使い回す（最初の音の遅れを無くす）。mlx-audio への報告・修正の提案
- ブラウザや body で、チャンクを届いた順に実際に鳴らす（今は届いた時刻からの計算だけ）
- 参照（人の録音・長さ・音質）と文を増やし、文字の誤り率（CER）としてまとめる
- 話者の近さを、両方と独立した埋め込み（ECAPA など）で測る
- CosyVoice 3 の RL 版の LLM（`llm.rl.pt`、モデルカードでは CER が低い）、Qwen3-TTS の VoiceDesign（文章で声を作る）、streaming の生成
- 速さ: Mac Studio・iPhone・Windows（MLX は Apple Silicon だけ）での速さ、チャンクを 0.25 秒にしたときの最初の音。製品に使うなら、どこで動かすか（body・brain・サーバー）と合わせて決める
- 数字や英字はカタカナに変換されない（UniDic に発音が無い）。CosyVoice 3 での読みは未確認
