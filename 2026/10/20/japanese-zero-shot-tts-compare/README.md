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

初回は、CosyVoice のコード（Matcha-TTS を含む）と 2 つのモデル、Whisper を取ります（合わせて約 10 GB）。
`http://127.0.0.1:8776/` を開き、画面の右上で 2 つのエンジンが「準備完了」になるのを待ちます。

1. **参照の声**: ファイルをドロップするか、マイクで録る。追加すると Whisper が自動で文字起こしする。
   違っていたら欄を直す（次の生成から使う）。共有の会話の素材の 2 人の話者も最初から選べる
2. **読ませる文**: 文を入れる（文の例のボタンあり）。CosyVoice 3 に渡すカタカナが下に出る
3. **両方で読ませる**: 2 つのエンジンを同時に動かし、結果に「参照の声・Qwen3-TTS・CosyVoice 3」を並べる。
   「文の例をすべて」は例の 7 文を順に生成する

オプション:

- 「参照の声の文字起こしを渡す」を外すと、声だけでまねる（Qwen3-TTS は x-vector だけ、CosyVoice 3 は cross-lingual）
- 「CosyVoice 3 にはカタカナにして渡す」を外すと、漢字かな交じりのまま渡す
- Qwen3-TTS のモデル（1.7B・0.6B）と seed

生成した音声は `output/webui/` に残ります（Git の対象外）。

## Structure

2 つのエンジンは依存がぶつかる（CosyVoice は torch 2.3.1・transformers 4.51.3、Qwen3-TTS は transformers 4.57.3）ので、
それぞれ `engines/<name>/` に別の Python 環境と worker を持ちます。

- `server.py`（Python 3.12）: Web UI、参照の声の変換（`afconvert` で 24 kHz mono）、Whisper の文字起こし、カタカナへの変換。
  worker を子プロセスとして起動し、stdin へ JSON の要求を送り、別のパイプ（`WORKER_REPLY_FD`）で返事を受ける
  （ライブラリが stdout に書くので、返事と分ける）
- `engines/qwen3_tts/worker.py`（Python 3.12、torch 2.14.1、`qwen-tts` 0.1.1）
- `engines/cosyvoice3/worker.py`（Python 3.11、upstream の `requirements.txt` のうち推論に要るものを同じ版で）

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

## Limitations and next steps

- 聞き比べは 1 人で、組み合わせを記録していない。量子化（bf16・8bit・4bit）の聞き比べもまだ
- 参照（人の録音・長さ・音質）と文を増やし、文字の誤り率（CER）としてまとめる
- 話者の近さを、両方と独立した埋め込み（ECAPA など）で測る
- CosyVoice 3 の RL 版の LLM（`llm.rl.pt`、モデルカードでは CER が低い）、Qwen3-TTS の VoiceDesign（文章で声を作る）、streaming の生成
- 速さ: MLX 版の Qwen3-TTS を Web UI の worker にする、streaming での最初の音までの時間、Mac Studio・CUDA の環境。製品に使うなら、どこで動かすか（body・brain・サーバー）と合わせて決める
- 数字や英字はカタカナに変換されない（UniDic に発音が無い）。CosyVoice 3 での読みは未確認
