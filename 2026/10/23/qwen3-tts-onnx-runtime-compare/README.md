# Qwen3-TTS ONNX Runtime ports vs MLX bf16 on Apple Silicon

Qwen3-TTS（12Hz Base）を ONNX Runtime で動かす公開の変換 2 つを、Mac で今使っている MLX bf16 と同じ参照の声・同じ文で比べます。
ONNX にすると、Mac と Windows を 1 つの実装（とアプリの中の ONNX Runtime）で動かせるかもしれない、というのが動機です。
Mac で実時間に届かなかったので、Windows（CUDA）でも同じものを測りました。

前の lab:
[CosyVoice 3 and Qwen3-TTS zero-shot voice cloning in Japanese](../../20/japanese-zero-shot-tts-compare/README.md)（MLX bf16 を選び、生成の設定を PyTorch に合わせた）、
[Qwen3-TTS MLX live clone](../../22/qwen3-tts-mlx-live-clone/README.md)（MLX での流しながらの生成）。

## Purpose

- 公開の ONNX 版は、Apple Silicon の Mac で実時間より速く生成できるか（最初の音までの時間・途切れ）
- Mac の GPU を使う道（ONNX Runtime の CoreML EP）は使えるか
- 声の質・読みは MLX bf16 と比べてどうか（人が聞いて判断する。補助に Whisper の文字誤り率）
- Windows の CUDA ならどうか

## Summary

2026-10-23。Mac は MacBook Pro（Apple M1 Max・64 GB）、Windows は Core i9-12900K・GeForce RTX 3080 Ti（12 GB）。7 文・seed 0 を各 1 回。

- **Mac では、どちらの ONNX 版も実時間に届かない**。MLX bf16 は実時間の 0.57 倍の時間で生成するのに対し、onnx-community 1.7B は CPU で 3.6〜4.4 倍、pltobing 0.6B は 6.8 倍
- **CoreML EP は肝心の部分に使えない**。talker と code predictor は CoreML の初期化で失敗し（int4・fp16・fp32 のどれも）、設定を変えて通した形は CPU と同じか遅い。速くなったのは音の復号器だけ（25 フレームで 475 → 173 ms）
- **Mac の CPU は 1 フレーム（80 ms の音）に約 250 ms かかる**（talker 1 歩 約 70 ms ＋ code predictor 11 ms × 15 回）。精度（fp32・fp16・int4）を変えてもほとんど変わらない
- **Windows の CUDA では pltobing 0.6B が実時間に収まった**: 実時間の 0.65 倍、最初の音 0.57 秒（M1 Max の MLX bf16 と同じくらい）。CUDA graph と IOBinding を前提にした作り。ただし声は話者の埋め込み（x-vector）だけでまね、参照の声の符号は使わない
- **onnx-community 1.7B は CUDA でも遅い**（int4 で 1.45 倍）。code predictor を 1 フレームに 15 回、毎回 16 個の符号の全部から計算し直す作りで、Python 側のサンプリングも含めて 1 フレームに約 115 ms。**`cuda_fp16` は壊れていて**、どの文も終わりの符号を出さずに 408 フレーム（32.6 秒）まで伸び、文字誤り率 0.94
- onnx-community の公開されたままの作り（`inference.py`）は、参照の声を 1 秒ずつ切って符号化するので 6.6 秒の参照が 91 フレームにずれ（MLX は 83）、復号も 25 フレームずつ切り離す。左の文脈を足すと 83 フレーム・復号の差も縮んだ（「Codec against MLX」）
- 声の質は聞いて判断する（`mise run listen`）。Whisper の文字誤り率では、壊れた CUDA fp16 以外は 0.03〜0.06 で大きな差は無い

解釈: Mac の上で ONNX Runtime に Qwen3-TTS を任せる道は、今の ONNX Runtime と公開の変換では閉じている。ONNX という形式の限界ではなく、Mac で GPU を使う良い道が ONNX Runtime に無いことと、変換の作りの問題。
Windows では、作りの良い変換（pltobing のような KV キャッシュ・CUDA graph）なら実用の速さになるが、1.7B で参照の符号を使うクローン（今 kiapi で使っている形）の変換は公開されていない。

その後: 同じ日に ggml の実装（qwentts.cpp）を測り（[qwen3-tts-ggml-compare](../qwen3-tts-ggml-compare/README.md)）、Mac・Windows とも 1.7B・ICL で最速だったので、エンジンはそちらにした。

## Run

macOS（Apple Silicon）、[uv](https://docs.astral.sh/uv/)、[mise](https://mise.jdx.dev/) が要ります。

```sh
mise -C 2026/10/23/qwen3-tts-onnx-runtime-compare run
```

モデルは Hugging Face のキャッシュに取り、onnx-community のものは `models/` に hard link で置きます（ONNX Runtime 1.31 は、
キャッシュの symlink を通ると外部データ `talker_cache.onnx.data` を「モデルのディレクトリの外」として読まない）。
ONNX 版は fp32・fp16・int4 と pltobing を合わせて約 32 GB、MLX bf16 と Whisper は前の lab と同じもの。

順に走るもの（`.mise/tasks/default`）:

1. `download.py`: 固定した commit で取る
2. `parity.py`: onnx-community の符号器・話者の埋め込み・復号器を MLX と比べる（`output/parity/`）
3. `components.py`: onnx-community の部品ごとの 1 回の時間（`output/components/`）
4. `bench.py`: 設定ごとに 7 文を生成して時間を測る（設定ごとに別のプロセス。最初に短い文を 1 回、数えずに流す）
5. `evaluate.py`: Whisper large-v3-turbo で文字起こしして文字誤り率を出し、`output/summary.md` と聞き比べのページを作る

聞き比べ: `mise run listen` で `http://127.0.0.1:8777/`（`output/index.html`）。参照の声と、文ごとに全部の設定が並びます。

### Windows (CUDA)

MLX が無いので別の環境（`windows/pyproject.toml`、`onnxruntime-gpu[cuda,cudnn]`）です。lab を Windows の PC に置き、
`output/reference-speaker1.wav`（Mac で作った参照の声）も一緒に置いてから:

```sh
uv sync --project windows
uv run --project windows components.py --precision fp16 --provider cuda
uv run --project windows bench.py pl --provider cuda
uv run --project windows bench.py oc --provider cuda --precision int4 --mode matched
uv run --project windows bench.py oc --provider cuda --precision fp16 --mode matched
uv run --project windows bench.py oc --provider cuda --precision fp16 --mode published
uv run --project windows voice_switch.py --provider cuda   # 話者 2 の参照 output/reference-speaker2.wav も Mac で作って置く
```

結果（`output/<設定>/`）を Mac の `output/windows/` に写してから `evaluate.py` を走らせると、文字起こしとページに入ります。

## What is compared

| 設定 | 中身 |
|---|---|
| `mlx-1.7b-bf16` | 基準。mlx-community の 1.7B Base bf16、mlx-audio 0.6.1。kiapi と同じ 2 つの直し（生成の設定を qwen-tts 0.1.1 に合わせる、流しの復号器を参照の符号で温める）。0.5 秒ずつ流す |
| `oc-1.7b-*` | [onnx-community/Qwen3-TTS-12Hz-1.7B-Base](https://huggingface.co/onnx-community/Qwen3-TTS-12Hz-1.7B-Base)。Olive で書き出した 9 つの部品。生成はこの lab の `engines/oc_engine.py`（変換に付く `inference.py` に沿う） |
| `pl-0.6b-fp32-*` | [pltobing/Qwen3-TTS-Streaming-ONNX](https://huggingface.co/pltobing/Qwen3-TTS-Streaming-ONNX)。0.6B Base の fp32。変換に付く推論のエンジンをそのまま使う（`engines/pl_engine.py` は呼ぶだけ） |

onnx-community の 2 つの作り:

- `published`: `inference.py` のとおり。プロンプトは非ストリーミングの並べ方（文を全部置いてから参照の符号）、参照は 1 秒ずつ独立に符号化（足りない分は 0 で埋める）、復号は 25 フレームずつ独立
- `matched`: プロンプトを qwen-tts 0.1.1 の既定（`non_streaming_mode=False`。参照の符号に文を重ね、余った文は 1 歩に 1 つずつ足す。MLX の基準と同じ）にし、
  参照は 6 フレームの左の文脈を付けて符号化して実際の長さに切りそろえ、復号は 12 フレームの左の文脈を付けて 13 フレームずつ

どちらも、生成は KV キャッシュ付きの talker（`talker_cache.onnx`。prefill は空の past）、code predictor は 1 フレームに 15 回、サンプリングは
`generation_config.json` の値（temperature 0.9・top-k 50・top-p 1.0・繰り返しの罰則 1.05 を生成した最初の符号の全部に）。復号は 13（`published` は 25）フレームたまるごとに行い、その時刻を「届いた時刻」とします。

pltobing は変換に付く既定の設定（temperature 0.75・top-p 0.85・top-k 50・繰り返しの罰則 9.5 を直近 75 個に）。文は 1 文字ずつ流し込み、4 フレーム（320 ms）ずつ復号します。
文ごとに `reset_turn(reset_cache=True, force_reset_codec_cache=True)` で前の文を持ち越しません（prefill のたびに参照の声から話者の埋め込みを計算し直すので、その時間も含む）。

条件をそろえられなかったところ:

- **モデルの大きさとまね方が違う**: pltobing は 0.6B で、参照の声は話者の埋め込みだけ（文字起こしも参照の符号も使わない）。MLX と onnx-community は 1.7B で、参照の符号と文字起こしも使う（ICL）
- **サンプリングが違う**: pltobing は変換の既定のまま。onnx-community は numpy、MLX は MLX の乱数なので、同じ seed でも同じ音にはならない
- 流し方: MLX は 0.5 秒ずつ、onnx-community は 13（25）フレーム、pltobing は 4 フレーム。最初の音までの時間はこの粒度に左右される
- MLX は生成のたびに参照の声を符号化し直す（mlx-audio の作り）。onnx-community は読み込み時に 1 回だけ（`reference_seconds`）

## Conditions

| | Mac | Windows |
|---|---|---|
| 機種 | MacBook Pro、Apple M1 Max（P コア 8・E コア 2）、64 GB | Core i9-12900K、GeForce RTX 3080 Ti 12 GB、64 GB |
| OS | macOS 27.0.1 | Windows 11（10.0.26220）、NVIDIA ドライバ 610.88 |
| Python | 3.12.10 | 3.12.15 |
| ONNX Runtime | `onnxruntime` 1.31.0（CPU・CoreML EP） | `onnxruntime-gpu` 1.31.0（CUDA EP）、CUDA 13.4（`nvidia-cuda-runtime` 13.4.92）、cuDNN 9.27.0.42 |
| ほか | mlx 0.32.4・mlx-audio 0.6.1・mlx-whisper 0.4.3、numpy 2.5.4、transformers 5.20.2 | numpy 2.5.4、transformers 5.20.2 |

- ONNX Runtime のセッションは、スレッドの空回り（`session.intra_op.allow_spinning`）を切っています。onnx-community は 8 つのセッションがそれぞれスレッドを持ち、
  空回りしたスレッドが動いているセッションの CPU を取り合います。既定のままだと int4 の 1 文が 92.9 秒（実時間の 11.4 倍）、切ると 35.4 秒（4.3 倍）で、同じ seed で同じ 102 フレームでした
- 参照の声: 共有の素材 `tests/assets/mp3/conversation_2speaker_14s_16k.mp3` の話者 1（前の lab と同じ区間、6.6 秒）を `afconvert` で 24 kHz にしたもの。文字起こしは既知
- 文: 前の lab の例の 7 文（`engines/common.py`）。seed 0、各 1 回

### Components

| Part | Source | Revision |
|---|---|---|
| onnx-community ONNX | Hugging Face `onnx-community/Qwen3-TTS-12Hz-1.7B-Base`（`cpu_fp32`・`cpu_fp16`・`cpu_int4`・`cuda_fp16`・`cuda_int4`） | `16ec6f3335d919e0e007d825a6f47fdd2cd77594` |
| pltobing ONNX と推論のエンジン | Hugging Face `pltobing/Qwen3-TTS-Streaming-ONNX` | `4e24bde29755c202827b109cd9e80e34ce5f097d` |
| config・tokenizer（onnx-community 用） | Hugging Face `Qwen/Qwen3-TTS-12Hz-1.7B-Base` | `fd4b254389122332181a7c3db7f27e918eec64e3` |
| MLX bf16 | Hugging Face `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16` | `a6eb4f68e4b056f1215157bb696209bc82a6db48` |
| Whisper | Hugging Face `mlx-community/whisper-large-v3-turbo` | `a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb` |

どれも Apache-2.0 です（各モデルカードの `license`）。pltobing の推論のコードは Git に入れず、取ったスナップショットから import します。

## Observed results (2026-10-23)

### Speed and transcription

`output/summary.md` から（RTF = 生成の時間 ÷ 音声の長さ、7 文の中央値。途切れは最初の音から再生し続けたときの無音の合計。CER は Whisper の文字起こしとの文字誤り率の平均）。

| 設定 | 機械 | RTF | 最初の音 | 途切れ（7 文の合計） | CER | 読み込み | メモリ |
|---|---|---:|---:|---:|---:|---:|---:|
| mlx-1.7b-bf16 | Mac | **0.57** | **0.58 秒** | 0.0 秒 | 0.038 | 7.2 秒 | 4.8 GB |
| oc-1.7b-fp32-published | Mac CPU | 3.80 | 8.21 秒 | 64.3 秒 | 0.029 | 4.8 秒 | 9.2 GB |
| oc-1.7b-fp32-matched | Mac CPU | 3.93 | 4.56 秒 | 93.6 秒 | 0.054 | 4.8 秒 | 9.2 GB |
| oc-1.7b-fp16-matched | Mac CPU | 4.17 | 4.77 秒 | 96.4 秒 | 0.057 | 6.3 秒 | 8.4 GB |
| oc-1.7b-int4-matched | Mac CPU | 4.42 | 5.09 秒 | 105.0 秒 | 0.038 | 2.2 秒 | 2.7 GB |
| oc-1.7b-fp32-matched-coreml | Mac CPU + codec は CoreML | 3.63 | 4.28 秒 | 84.0 秒 | 0.054 | 51.6 秒 | 9.1 GB |
| pl-0.6b-fp32-published-t8 | Mac CPU（8 スレッド） | 6.84 | 4.09 秒 | 236.2 秒 | 0.048 | 4.3 秒 | 8.8 GB |
| pl-0.6b-fp32-published-cuda | Windows CUDA | **0.65** | **0.57 秒** | 9.5 秒 | 0.056 | 9.5 秒 | 14.4 GB |
| oc-1.7b-fp16-published-cuda | Windows CUDA | 1.89 | 3.74 秒 | 186.8 秒 | **0.944** | 5.9 秒 | 10.3 GB |
| oc-1.7b-fp16-matched-cuda | Windows CUDA | 1.92 | 2.00 秒 | 201.1 秒 | **0.944** | 5.9 秒 | 10.3 GB |
| oc-1.7b-int4-matched-cuda | Windows CUDA | 1.45 | 1.52 秒 | 13.4 秒 | 0.062 | 4.7 秒 | 7.7 GB |

メモリは Mac がプロセスの `phys_footprint`、Windows は private bytes（CUDA の固定メモリを含むので GPU の上の量ではない）。

- MLX の途切れ 0 は、生成が再生より速く、0.5 秒ずつ届くため
- pltobing の CUDA は RTF が 1 より小さいのに途切れが 9.5 秒ある。文を 1 文字ずつ流し込み、話し始めのあたりで文が足りない間に生成が待つため（推測。文ごとの到着の帯で見ていない）
- Mac での pltobing は、最初に 1 文だけ試したときは実時間の 22.7 倍（194 秒）だった。7 文の本番では 6.8 倍で、差の原因は確かめていない
- **`cuda_fp16` は 7 文すべてで 408 フレームちょうどで止まり、終わりの符号を出さなかった**（`published`・`matched` とも）。同じ作りの `cpu_fp16`（Mac）と `cuda_int4` は普通に終わる。
  Whisper の文字起こしは文と無関係。原因（書き出しの fp16 の数値、CUDA の Attention の実装など）は調べていない

### Where the time goes (onnx-community)

`components.py`（1 回の時間の中央値、past 150、ms）:

| 機械・EP | talker 1 歩 | code predictor 1 回 | 復号器 25 フレーム | 1 フレームの見積もり（`matched`） |
|---|---:|---:|---:|---:|
| Mac CPU fp32 | 69.8 | 10.5 | 475.0 | 263.8 |
| Mac CPU fp16 | 67.1 | 11.0 | 478.3 | 268.9 |
| Mac CPU int4 | 75.4 | 12.7 | 510.6 | 305.3 |
| Mac CPU int4、8 スレッド | 111.0 | 13.7 | 649.1 | 366.5 |
| Mac CPU int4、4 スレッド | 96.8 | 16.6 | 592.7 | 391.4 |
| Mac CoreML（MLProgram）fp32 | 失敗 | 失敗 | 170.5 | — |
| Mac CoreML（静的な形のみ）fp32 | 77.1 | 14.8 | 173.7 | 312.5 |
| Mac CoreML（NeuralNetwork）fp32 | 98.3 | 29.1 | 1767.2 | 676.7 |
| Windows CUDA fp16 | 24.1 | 3.0 | 28.7 | 71.6 |
| Windows CUDA int4 | 27.1 | 2.7 | 26.9 | 69.9 |

- 実時間には 1 フレーム 80 ms 未満が要る。Mac の CPU はどの精度・スレッド数でも 250 ms を超える。スレッド数は既定（このマシンでは全コア）が最も速かった
- CoreML の MLProgram は、talker（`HandleNegativeAxis ... axis 3 is not in valid range [-3,2]`）と code predictor（`Failed to build the model execution plan`）の初期化で失敗。
  静的な形だけを CoreML に渡す設定と NeuralNetwork 形式は初期化できるが、talker と code predictor は速くならない。復号器だけは MLProgram で約 2.7 倍速い（読み込みに 42〜47 秒）
- CUDA の部品は 1 フレーム 70 ms で収まる計算だが、生成の全体では 1 フレームに約 115 ms（int4: talker 32 ms・code predictor 81 ms）。code predictor の 15 回の呼び出しごとに、
  numpy のサンプリング（2048 語彙の top-k）と ONNX Runtime の呼び出しの手間が乗る
- `components.py` の CUDA は、KV キャッシュを毎回 CPU から渡す素の測り方。生成（`bench.py`）は talker の KV を IOBinding で GPU の上に置いたまま回す
- fp32 は Windows の 12 GB に収まらない。1 文だけ試すと復号器が 1 回に約 2 秒かかり（RTF 4.2）、本番から外した

### Codec against MLX

`parity.py`（`output/parity/parity.json`）。MLX の符号器・復号器を物差しにして、同じ参照の声（6.6 秒）で比べました。

| | `published` | `matched` |
|---|---:|---:|
| 参照の符号のフレーム数（MLX は 83） | 91 | 83 |
| 1 番目の符号帳が MLX と一致 | 16.9% | 77.1% |
| 全部の符号帳が MLX と一致 | 14.2% | 37.3% |
| 復号の MLX とのスペクトルの距離（LSD） | 8.02 dB | 5.71 dB |

- 話者の埋め込み（x-vector）は MLX とコサイン 1.000000
- 復号器は因果的（25 フレームのうち後ろを入れ替えても、前の 13 フレームの波形は 0.0 の差）。なので左の文脈を足して前から切り出せる
- 符号器の左の文脈を 3・6・9・11 フレームにすると、1 番目の符号帳の一致は 72〜80%。1 秒の入力に固定された書き出しなので、それより長い文脈は渡せない
- 復号器の左の文脈を 0・6・12・18・24 フレームにすると、LSD は 8.0・7.1・5.7・5.5・6.4 dB。この lab は 12 を使う。
  参考に、MLX の復号そのものの元の声との LSD は 10.8 dB（符号にする時点で失うもの）
- 波形の SNR は文脈の長さと単調に動かなかった（6 フレームで 11.8 dB、12 で 6.1 dB）ので、評価には使っていない

### Listening

- 2026-10-23、lab の作者 1 人が `mise run listen` で聞いた: `windows/pl-0.6b-fp32-published-cuda` は「まあ、使えるレベル」。ほかの列の評価、MLX との並べた比較の言葉は記録していない

### Switching the reference voice (pltobing, Windows CUDA)

`voice_switch.py`（`output/voice-switch/`。聞くのは `mise run listen` の `/windows/voice-switch/`）。1 つのエンジンのまま、参照を共有の素材の話者 1 → 話者 2 → 話者 1 と替えて、1 文目を seed 0 で読ませた。

- 変換の API には参照を替える口が無い（参照のパスは作るときに渡し、prefill のたびにそこから x-vector を計算する）。パスを差し替え、続けて話すモード用に持っている参照の切れ端の履歴を消し、`reset_turn(reset_cache=True, force_reset_codec_cache=True)` すれば替わった
- x-vector の計算は 0.05〜0.11 秒。生成は 3 回とも実時間の 0.64 倍前後、最初の音 0.53〜0.57 秒
- 話者 1 に戻した 3 回目は、1 回目とバイト単位で同じ音（前の声は残らない）
- 話者 1 と 2 の x-vector のコサインは 0.967（この話者の埋め込みでは 2 人がかなり近い）。声が替わって聞こえるかは聞いて判断する

### Other reference voices

`REFERENCE_LABEL`・`REFERENCE_AUDIO`・`REFERENCE_TEXT_FILE` の環境変数で、話者 1 の代わりに別の参照の声を使えます（`engines/common.py`）。参照の音声は lab に含めません。

```sh
REFERENCE_LABEL=mine REFERENCE_AUDIO=path/to/voice.wav REFERENCE_TEXT_FILE=path/to/transcript.txt uv run --frozen bench.py mlx
```

2026-10-23 に、フリー素材のキャラクターの声（10.7 秒、悲しみの読み）を参照にして、MLX bf16（Mac、文字起こしは Whisper）と pltobing 0.6B（Windows CUDA）で 7 文を作り、
聞き比べた（`output/kanashimi.html`、この lab の外の音声）。速さは MLX が実時間の 0.56 倍・最初の音 0.75 秒、pltobing が 0.67 倍・0.60 秒で、話者 1 のときと同じ傾向。

## Limitations

- 7 文・seed 1 つ・各 1 回。時間のばらつきは測っていない（Mac の各設定の文ごとの RTF は ±5% 程度にそろっていた）
- 声の質は人が聞いて判断する前の段階。CER は読みの破綻を見るだけで、声の似かたは見ていない
- onnx-community の生成はこの lab の実装（`inference.py` に沿う）。サンプリングを ONNX の中に入れる、code predictor を KV キャッシュ付きで書き出し直すなどの改善はしていない
- pltobing の 0.6B と 1.7B の違い、x-vector だけと ICL の違いは分けていない
- Windows の測定は 1 台。CUDA graph を使わない pltobing、TensorRT EP、DirectML は試していない
- Mac の GPU を ONNX から使う別の道（ONNX Runtime の WebGPU EP、CoreML が受け付ける形での書き出し直し）は試していない
