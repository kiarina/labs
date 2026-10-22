# Qwen3-TTS on ggml (qwentts.cpp, llama.cpp) vs MLX bf16 and an ONNX Runtime port

Qwen3-TTS（12Hz Base）の ggml の実装 2 つを、Mac（Metal）と Windows（CUDA）で、今使っている MLX bf16 と、前の lab で Windows に使えそうだった pltobing の ONNX 版に並べて測ります。
同じ参照の声・同じ 7 文です。

動機: 前の lab [Qwen3-TTS ONNX Runtime ports vs MLX bf16 on Apple Silicon](../qwen3-tts-onnx-runtime-compare/README.md) で、ONNX Runtime は Mac で実時間に届かず、
「Mac は MLX、Windows は ONNX」と実装を 2 本持つ案になった。ggml なら 1 本の C++ 実装で Metal・CUDA・Vulkan の全部を受け持てるかもしれない。

## Purpose

- ggml の実装は、Mac の Metal と Windows の CUDA で、MLX bf16・pltobing ONNX より速いか（実時間の何倍か、最初の音までの時間）
- 参照の文字起こしを使うクローン（ICL）を、Mac と Windows で同じ実装・同じ声質で動かせるか
- 1 つのサーバーで同時に何本まで実時間で話せるか
- 声の質（人が聞いて判断する。補助に Whisper の文字誤り率）

## Summary

2026-10-23。Mac は MacBook Pro（Apple M1 Max・64 GB）、Windows は Core i9-12900K・GeForce RTX 3080 Ti（12 GB）。7 文・seed 0 を各 1 回。

- **qwentts.cpp が Mac でも Windows でも一番速い**。1.7B Q8_0（参照の符号と文字起こしで似せる ICL）は、Mac の Metal で実時間の 0.40 倍・最初の音 0.09 秒、Windows の CUDA で 0.15 倍・0.03 秒。
  MLX bf16（Mac）は 0.56 倍・0.58 秒、pltobing 0.6B（Windows CUDA）は 0.52 倍・0.42 秒
- **1 本の実装で Mac と Windows の両方が 1.7B・ICL で動く**。量子化（BF16・Q8_0・Q4_K_M）と 0.6B もどれも実時間を大きく下回る
- **同時に話せる**: `--max-batch` で同時の要求をまとめて GPU に流せる。Mac は 4 本同時でもどれも実時間の 0.6〜0.7 倍。Windows は 4 本で 0.32〜0.38 倍、8 本で崩れた（1 本 23〜31 倍。12 GB の VRAM に収まらないと見られる）
- **llama.cpp 本家の `llama-tts` は CLI だけ**で、文ごとにモデルを読み直し、参照の声のファイルだけを渡す（文字起こしは渡せない）。読み込み込みで実時間の 0.7 倍、最初の音（＝全部できたとき）4〜4.6 秒
- 文字誤り率は、どの設定も 0.02〜0.06 で大きな差は無い。声の似かたと自然さは聞いて判断する（`mise run listen`）

解釈: qwentts.cpp は、口（OpenAI 互換のサーバーと声の登録）・C の ABI・流しの生成・同時の要求まで揃っており、「1 本の実装で Mac と Windows」の理想にほぼそのまま当てはまる。
残るのは声の質の判断（MLX と並べて聞く）と、流し込みながら話す（文を足しながら生成する）口が無いことの扱い。

## Run

macOS（Apple Silicon）、[uv](https://docs.astral.sh/uv/)、[mise](https://mise.jdx.dev/)、Xcode のコマンドラインツールと CMake が要ります。

```sh
mise -C 2026/10/23/qwen3-tts-ggml-compare run
```

`.mise/tasks/default` は、qwentts.cpp を固定の commit で取って Metal で build し（`vendor/`）、重みと llama.cpp のリリースのバイナリを取り（`download.py`。バイナリは `bin/`）、
Mac の設定を全部走らせ（`bench.py`、`concurrency.py`）、Whisper で文字起こしして要約と聞き比べのページを作ります（`evaluate.py`）。

聞き比べ: `mise run listen` で `http://127.0.0.1:8778/`（`output/index.html`）。参照の声と、文ごとに全部の設定が並びます。

### Windows (CUDA)

Visual Studio 2022（C++）、CUDA Toolkit 13.4（`winget install -e --id Nvidia.CUDA`）、uv が要ります。lab を Windows の PC に置き、`output/reference-speaker1.wav`（Mac で作った参照の声）も置いてから:

```bat
git clone --recurse-submodules https://github.com/ServeurpersoCom/qwentts.cpp.git vendor\qwentts.cpp
git -C vendor\qwentts.cpp checkout 5916bf7c79dbb4e66fc059cdc507a79a23a28bb4
git -C vendor\qwentts.cpp submodule update --init --recursive
windows\build-qwentts-cuda.cmd
uv sync --project windows
windows\run.cmd download.py
windows\run.cmd bench.py qwentts --talker 1.7b-base-Q8_0
windows\run.cmd bench.py llama
windows\run.cmd bench.py pl
windows\run.cmd concurrency.py --counts 1 2 4 8
```

`windows\run.cmd` は CUDA Toolkit の DLL を PATH に足してから `uv run --project windows` を呼びます（入れた直後の ssh のセッションには、インストーラが足した PATH が入らない）。
結果（`output/<設定>/`）を Mac の `output/windows/` に写してから `evaluate.py` を走らせると、文字起こしとページに入ります。

## What is compared

| 設定 | 中身 |
|---|---|
| `qwentts-*` | [qwentts.cpp](https://github.com/ServeurpersoCom/qwentts.cpp)（MIT）の `tts-server`。重みは [Serveurperso/Qwen3-TTS-GGUF](https://huggingface.co/Serveurperso/Qwen3-TTS-GGUF)。talker（1.7B の BF16・Q8_0・Q4_K_M、0.6B の Q8_0）と 12 Hz の codec（F32） |
| `qwentts-*-xvector` | 同じで、声を文字起こしなしで登録（話者の埋め込みだけでまねる） |
| `llama-tts-1.7b-Q8_0` | [llama.cpp](https://github.com/ggml-org/llama.cpp)（MIT）の `llama-tts`（Qwen3-TTS は [#26254](https://github.com/ggml-org/llama.cpp/pull/26254) で対応）。リリース `b11827` のバイナリ（macOS arm64、Windows CUDA 13.4）、重みは ggml-org の公式の GGUF |
| `mlx-1.7b-bf16` | 基準。mlx-community の 1.7B Base bf16、mlx-audio 0.6.1、kiapi と同じ 2 つの直し（前の lab と同じ `engines/mlx_engine.py`） |
| `pl-0.6b-fp32-published-cuda` | 前の lab で Windows に使えそうだった [pltobing/Qwen3-TTS-Streaming-ONNX](https://huggingface.co/pltobing/Qwen3-TTS-Streaming-ONNX)（0.6B、x-vector だけ）の CUDA |

qwentts.cpp の使い方（`engines/qwentts_engine.py`）:

- サーバーを 1 回起動し、参照の声を `POST /v1/audio/voices` に `wav_b64` と `ref_text` で登録する。サーバーが話者の埋め込みと参照の符号を作り、ICL で似せる
- 文ごとに `POST /v1/audio/speech`（`response_format: "pcm"`、seed 0）。s16le 24 kHz が、1 フレーム（80 ms）ずつ復号されるたびに流れてくる。最初に届いた時刻を「最初の音」にする
- サンプリングはエンジンの既定で、`generation_config.json` と同じ（temperature 0.9・top-k 50・top-p 1.0・繰り返しの罰則 1.05、sub-talker も 0.9・50・1.0）
- プロンプトは qwen-tts の既定（`non_streaming_mode=False`。参照の符号に文を重ね、余った文は 1 歩に 1 つずつ足す）と同じ並べ方（`src/prompt-builder.h`）。MLX の基準と同じ

条件をそろえられなかったところ:

- qwentts.cpp と MLX は乱数の作りが違う（Philox と MLX）ので、同じ seed でも同じ音にはならない
- 流し方: qwentts.cpp は 1 フレームずつ、MLX は 0.5 秒ずつ、pltobing は 4 フレームずつ、llama-tts は流さない。最初の音までの時間はこの粒度にも左右される
- llama-tts は文ごとにモデルを読み直す（CLI）ので、時間に読み込みを含む。参照の文字起こしを渡す口が無い
- MLX は生成のたびに参照の声を符号化し直す。qwentts.cpp は登録のときに 1 回（Mac 0.58 秒・Windows 0.48 秒）
- pltobing は 0.6B・x-vector だけで、サンプリングは変換の既定（temperature 0.75・top-p 0.85・繰り返しの罰則 9.5 を直近 75 個に）

## Conditions

| | Mac | Windows |
|---|---|---|
| 機種 | MacBook Pro、Apple M1 Max、64 GB | Core i9-12900K、GeForce RTX 3080 Ti 12 GB、64 GB |
| OS | macOS 27.0.1 | Windows 11（10.0.26220）、NVIDIA ドライバ 610.88 |
| qwentts.cpp | `5916bf7c79dbb4e66fc059cdc507a79a23a28bb4`（2026-10-16）、ggml `cc5df49`（submodule）、`-DGGML_METAL=ON`、AppleClang | 同じ commit、`-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=86`、MSVC（VS 2022）、CUDA Toolkit 13.4（13.4.1）、Ninja |
| llama.cpp | リリース `b11827`（macOS arm64） | リリース `b11827`（Windows CUDA 13.4 と cudart） |
| Python | 3.12.10、mlx 0.32.4・mlx-audio 0.6.1・mlx-whisper 0.4.3 | 3.12.15、onnxruntime-gpu 1.31.0（pltobing） |

- 参照の声: 共有の素材 `tests/assets/mp3/conversation_2speaker_14s_16k.mp3` の話者 1（前の lab と同じ区間、6.6 秒）を `afconvert` で 24 kHz にしたもの。文字起こしは既知
- 文: 前の lab と同じ 7 文（`engines/common.py`）。seed 0、各 1 回。最初に短い文を 1 回、数えずに流す
- メモリは、qwentts.cpp はサーバーのプロセス（Mac は `phys_footprint`、Windows は private bytes）、ほかは測っているプロセス。llama-tts は CLI を呼ぶ側だけなので参考にならない

### Components

| Part | Source | Revision |
|---|---|---|
| qwentts.cpp | GitHub `ServeurpersoCom/qwentts.cpp`（MIT） | `5916bf7c79dbb4e66fc059cdc507a79a23a28bb4` |
| qwentts.cpp の GGUF | Hugging Face `Serveurperso/Qwen3-TTS-GGUF` | `b7ee2e8c7459c3bea99da23e3d178125a7d1713c` |
| llama.cpp | GitHub `ggml-org/llama.cpp` のリリース（MIT） | `b11827` |
| llama.cpp の GGUF | Hugging Face `ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF`（Q8_0 と mmproj Q8_0） | `ca27d74bc954b73dadab5b71ca265d87fc861a7c` |
| MLX bf16 | Hugging Face `mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16` | `a6eb4f68e4b056f1215157bb696209bc82a6db48` |
| pltobing ONNX | Hugging Face `pltobing/Qwen3-TTS-Streaming-ONNX` | `4e24bde29755c202827b109cd9e80e34ce5f097d` |
| Whisper | Hugging Face `mlx-community/whisper-large-v3-turbo` | `a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb` |

モデルは Qwen3-TTS（Apache-2.0）。qwentts.cpp と llama.cpp は Git に入れず、build・取得します（`vendor/`・`bin/`）。

## Observed results (2026-10-23)

### Speed and transcription

`output/summary.md` から（RTF = 生成の時間 ÷ 音声の長さ、7 文の中央値。途切れは最初の音から再生し続けたときの無音の合計。CER は Whisper の文字起こしとの文字誤り率の平均）。

| 設定 | 機械 | RTF | 最初の音 | 途切れ | CER | 読み込み | メモリ |
|---|---|---:|---:|---:|---:|---:|---:|
| mlx-1.7b-bf16 | Mac | 0.56 | 0.58 秒 | 0 | 0.038 | 11.8 秒 | 4.8 GB |
| qwentts-1.7b-base-BF16 | Mac Metal | 0.46 | 0.09 秒 | 0 | 0.047 | 2.2 秒 | 5.5 GB |
| **qwentts-1.7b-base-Q8_0** | Mac Metal | **0.40** | **0.09 秒** | 0 | 0.038 | 1.6 秒 | 3.7 GB |
| qwentts-1.7b-base-Q4_K_M | Mac Metal | 0.37 | 0.09 秒 | 0 | 0.044 | 1.6 秒 | 2.9 GB |
| qwentts-0.6b-base-Q8_0 | Mac Metal | 0.37 | 0.06 秒 | 0 | 0.062 | 1.6 秒 | 2.7 GB |
| qwentts-1.7b-base-Q8_0-xvector | Mac Metal | 0.40 | 0.06 秒 | 0 | 0.018 | 1.6 秒 | 3.7 GB |
| llama-tts-1.7b-Q8_0 | Mac Metal | 0.73 | 4.63 秒 | 0 | 0.023 | （文ごと） | — |
| qwentts-1.7b-base-BF16 | Windows CUDA | 0.20 | 0.03 秒 | 0 | 0.056 | 2.5 秒 | 7.5 GB |
| **qwentts-1.7b-base-Q8_0** | Windows CUDA | **0.15** | **0.03 秒** | 0 | 0.037 | 2.0 秒 | 5.6 GB |
| qwentts-1.7b-base-Q4_K_M | Windows CUDA | 0.13 | 0.03 秒 | 0 | 0.061 | 2.0 秒 | 4.7 GB |
| qwentts-0.6b-base-Q8_0 | Windows CUDA | 0.13 | 0.02 秒 | 0 | 0.056 | 2.0 秒 | 4.5 GB |
| qwentts-1.7b-base-Q8_0-xvector | Windows CUDA | 0.15 | 0.03 秒 | 0 | 0.032 | 2.0 秒 | 5.5 GB |
| llama-tts-1.7b-Q8_0 | Windows CUDA | 0.70 | 4.01 秒 | 0 | 0.032 | （文ごと） | — |
| pl-0.6b-fp32-published-cuda | Windows CUDA | 0.52 | 0.42 秒 | 3.7 秒 | 0.056 | 8.2 秒 | 14.4 GB |

- qwentts.cpp の 1 文目（6.9 秒の音）の内訳（サーバーのログの `[Perf]`、Mac Metal、Q8_0）: prefill 49 ms、talker 8.0 ms/フレーム、code predictor 17.0 ms/フレーム、codec の復号 594 ms（合わせて 25 ms/フレーム）。
  Windows CUDA は talker 4.0 ms/フレーム、code predictor 7.0 ms/フレーム、codec 71 ms（11 ms/フレーム）
- 量子化を下げても速さは少ししか変わらない（Mac で BF16 0.46 → Q4_K_M 0.37）。1 フレームの時間の多くは code predictor（15 段）と復号
- pltobing の CUDA は前の lab（0.65 倍・0.57 秒）より速かった（0.52 倍・0.42 秒）。同じ機械・同じ版で、差の原因は確かめていない
- MLX の読み込み 11.8 秒は、前の lab（7.2 秒）より長い。直前に別のプロセスが走っていたかなど、条件は確かめていない

### Several requests at once (qwentts.cpp 1.7B Q8_0)

`concurrency.py`（`output/concurrency-*.json`）。1 つのサーバー（`--max-batch` = 最大の同時数）に、1 文目から N 文目までを同時に投げた。

| 同時 | Mac Metal の各 RTF | Mac の最初の音 | Windows CUDA の各 RTF | Windows の最初の音 |
|---:|---|---:|---|---:|
| 1 | 0.39 | 0.08 秒 | 0.15 | 0.03 秒 |
| 2 | 0.52・0.61 | 0.35 秒 | 0.18・0.21 | 0.07 秒 |
| 4 | 0.60・0.70・0.63・0.67 | 0.35 秒 | 0.32・0.36・0.37・0.38 | 0.10 秒 |
| 8 | — | — | 14〜31（崩れた） | 0.19 秒 |

- 4 本までは全部が実時間を下回り、途切れも Mac で 0.3〜0.4 秒（最初の音の後に 1 回）、Windows で 0
- Windows の 8 本は、サーバーのログで codec の復号に 150 秒かかっていた。12 GB の VRAM を超えて共有メモリに溢れたと見られる（確かめていない）

### Listening

（オーナーが `mise run listen` で聞いた結果をここに書く。未）

## Limitations

- 7 文・seed 1 つ・各 1 回。速さのばらつきは測っていない
- 声の質は人が聞いて判断する前。CER は読みの破綻を見るだけ
- qwentts.cpp の口は「全文を渡して流しで受け取る」形で、文を少しずつ足しながら生成する口（kiapi の版 2 の `text.append`）は無い。通話の短区間ごとに投げる使い方は試していない
- qwentts.cpp の forward が PyTorch と一致することは作者の検証（README の Validation）に頼っていて、この lab では確かめていない
- llama.cpp は CLI だけを測った。`llama-server` で TTS を常駐させる形は試していない
- AMD・Intel の GPU（Vulkan）、iOS・Android は試していない
