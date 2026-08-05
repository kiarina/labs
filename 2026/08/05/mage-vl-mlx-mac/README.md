# Mage-VL on MLX and Apple Silicon

Microsoft の `Mage-VL` と、その MLX 移植および Apple Silicon 上の動作報告を
2026-08-05 時点で調査した記録です。名称は `Mega-VL` ではなく `Mage-VL` です。
この lab ではモデルを実行しておらず、Mac での追試手順と評価項目を定めるところまでを
扱います。

## 目的と問い

次の点を明らかにします。

- Mage-VL の公式実装に MLX または macOS 対応があるか
- MLX-VLM に取り込まれた移植で、どの機能まで利用できるか
- Apple Silicon 上の具体的な動作報告と測定値があるか
- Mac で追試するとき、何を公式情報、第三者報告、自分の観測として区別すべきか

評価は公開された model card、実装、issue、pull request を相互に確認して行います。
単に Hugging Face に `mlx` tag のある checkpoint が存在するだけでは対応済みとせず、
実装の merge 状態、対応入力、参照実装との一致検証を確認します。

## 調査対象

Mage-VL は Qwen3-4B-Instruct-2507 decoder と独自の Mage-ViT を組み合わせた
約 47.4 億 parameter の vision-language model です。静止画、動画、時系列位置推定、
イベント駆動の proactive streaming を一つの checkpoint で扱います。

動画では全 frame を均等に token 化する代わりに、I frame の patch と、P frame の
motion vector・residual energy が示す変化の大きい patch を使用します。Microsoft は、
この codec-native 経路について visual token を 75% 以上削減し、均等 frame sampling
比で最大 3.5 倍高速になったと報告しています。これは Microsoft の論文上の結果であり、
本 lab で追試した値ではありません。

公式 checkpoint は BF16 で約 10.8 GB、Hugging Face API 上の parameter 数は
4,741,793,792 です。Microsoft の inference requirements は Python 3.10 以上、
PyTorch 2.9 以上、Transformers 5.7 以上を要求し、codec および streaming 経路は
`codec-video-prep`、`mamba-ssm`、`flash-attn`、FFmpeg などに依存します。
公式 repository と model card には MLX や MPS の実行手順はありません。

## MLX 対応状況

### MLX-VLM の標準実装

`Blaizzy/mlx-vlm` の pull request 1745 が 2026-07-29 に merge され、
`mage_vl` architecture が MLX-VLM に追加されています。実装は Mage-ViT と
Qwen3 decoder を MLX で構成し、静止画入力について次を検証しています。

- PyTorch reference に対する vision tower の相対誤差は `4.0e-5` 以下、cosine は 1.0
- 重み key は 696 対 696 で missing / unused ともに 0
- 参照画像に対する greedy generation は 48 token すべて一致
- `mlx-community/Mage-VL-8bit` でも 48 token すべて一致
- Mage-VL 関連 test は 9 件成功

ただし merge 時点の対象は静止画だけです。upstream の video path が
manylinux 向け native extension または PyTorch frame sampler に依存するため、
torch-free video は後続作業とされています。2026-08-05 時点で frame-sampled video
対応の issue 1766 は open です。codec-sparse patch selection は、さらに別の
follow-up とされています。

確認できた変換済み checkpoint は次のとおりです。容量は 2026-08-05 に
Hugging Face API から取得した repository storage で、実行時 memory ではありません。

| Checkpoint | 方式 | repository storage | 標準実装で確認された範囲 |
|---|---|---:|---|
| `mlx-community/Mage-VL-8bit` | 8 bit | 約 5.37 GB | 静止画 |
| `mlx-community/Mage-VL-OptiQ-4bit` | mixed 4 bit | 約 3.93 GB | 静止画 |
| `sahilchachra/mage-vl-mxfp4-mlx` | MXFP4 | 約 3.02 GB | 静止画 |

### 第三者の動画・streaming 移植

`rsravanreddy/Mage-VL-MLX` と `sr29/Mage-VL-mlx-4bit` は、標準 MLX-VLM 実装とは
別に、静止画、frame-sampled video、proactive streaming gate の移植を公開しています。
重みは group size 64 の 4 bit で約 3.1 GB です。

model card が報告する Apple M4、16 GB unified memory 上の値は次のとおりです。
これは移植者の測定であり、本 lab の観測結果ではありません。

| 量子化 | 重み | image decode | image peak RAM |
|---|---:|---:|---:|
| 4 bit | 3.1 GB | 30.6 token/s | 4.65 GB |
| 8 bit | 5.0 GB | 19.1 token/s | 6.55 GB |

移植者は image preprocessing の参照実装との完全一致、24 層 vision tower の
最大絶対誤差 `3.0e-4`、streaming Mamba mixer の誤差 `4.3e-7`、画像と動画の
定性的に正しい生成を報告しています。一方、PyTorch 版との end-to-end logit parity、
動画速度、動画 peak memory、codec-native token 削減の再現は未確認です。

この第三者実装は `mlx-vlm` package 内へ model plugin の symbolic link を作る手順を
要求します。また、codec-native video backend には外部 codec engine が必要です。
したがって「Mage-VL の全機能が MLX だけで動く」とはまだ言えません。

## 2026-08-05 時点の結論

- 公式 Microsoft 実装は CUDA / PyTorch 中心で、公式 MLX・MPS 対応はない
- MLX-VLM には静止画対応が merge 済みで、参照 PyTorch 実装との token 一致まで確認済み
- Mac の具体的な動作報告はあり、M4 16 GB で 4 bit が 30.6 token/s、peak RAM
  4.65 GB と報告されている
- frame-sampled video と streaming gate は第三者移植で動作報告があるが、標準
  MLX-VLM では未対応または作業中
- Mage-VL の主要な特徴である codec-native sparse video 経路を Apple Silicon 上で
  再現できたという定量報告は確認できない

したがって、Mac では静止画推論を再現する段階には達していますが、動画と proactive
streaming は実験的、codec-native 経路は未確立と評価します。

## Mac への引き継ぎ

### 1. 標準 MLX-VLM で静止画を確認する

最初に新しい virtual environment を作り、実行時の package version と model revision を
記録します。以下は checkpoint を Hugging Face cache にダウンロードします。

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip mlx-vlm
python -m pip freeze > output/pip-freeze.txt

mlx_vlm.generate \
  --model mlx-community/Mage-VL-8bit \
  --max-tokens 100 \
  --temperature 0 \
  --image path/to/image.jpg \
  --prompt "Describe this image."
```

実行前後に macOS version、chip、unified memory、MLX version を記録します。

```sh
mkdir -p output
sw_vers > output/sw-vers.txt
system_profiler SPHardwareDataType > output/hardware.txt
python -c 'import mlx; print(mlx.__version__)' > output/mlx-version.txt
```

### 2. 第三者移植で動画を確認する

静止画が成功した後にだけ、移植 repository の README に従って
`sr29/Mage-VL-mlx-4bit` を試します。移植コードと model revision は commit hash に固定し、
package directory への symbolic link が既存環境を変更するため、手順 1 とは別の
virtual environment を使います。

最低限、次を別々に測定します。

- 静止画と 8 frame 動画の model load time、time to first token、decode token/s
- MLX allocator peak memory、process peak RSS、swap 使用量
- 同じ動画に対する frame-sampled 経路と codec-native 経路の token 数
- streaming gate の speak / silent timeline と、人手で付けた event 時刻との差
- 4 bit と 8 bit の出力差。同じ prompt、input、temperature 0 を使用する

結果は model card の M4 16 GB 値と混ぜず、Mac で実際に観測した値として追記します。
失敗した入力、未対応 operation、fallback、crash、swap 発生も記録します。

## 未確認事項と制約

- 本調査では checkpoint の download、変換、推論を実施していない
- MLX checkpoint と repository は公開直後で、tag、実装、対応範囲が変わり得る
- M4 16 GB の性能値は単一の第三者 model card による報告で、独立追試ではない
- 4 bit と 8 bit は生成品質が同一とは限らない。移植者は 8 bit の方が richer output と
  しているが、定量品質評価は示していない
- 静止画の一致検証から、動画、streaming、codec path の一致を推論できない
- Microsoft の最大 3.5 倍という速度値は B200 環境を含む公式評価で、Mac へ適用できない
- model cache と virtual environment は数 GB を使用する。生成物は Git に追加しない

## 参照

- [Mage-VL paper](https://arxiv.org/abs/2607.24904)
- [Microsoft Mage-VL model card](https://huggingface.co/microsoft/Mage-VL)
- [Microsoft Mage repository](https://github.com/microsoft/Mage/tree/main/mage_vl)
- [Mage-VL requirements](https://github.com/microsoft/Mage/blob/main/mage_vl/requirements.txt)
- [MLX-VLM Mage-VL merge](https://github.com/Blaizzy/mlx-vlm/pull/1745)
- [MLX-VLM frame-sampled video issue](https://github.com/Blaizzy/mlx-vlm/issues/1766)
- [MLX-VLM](https://github.com/Blaizzy/mlx-vlm)
- [MLX 8-bit checkpoint](https://huggingface.co/mlx-community/Mage-VL-8bit)
- [MLX OptiQ 4-bit checkpoint](https://huggingface.co/mlx-community/Mage-VL-OptiQ-4bit)
- [Independent MLX port](https://github.com/rsravanreddy/Mage-VL-MLX)
- [Independent MLX 4-bit checkpoint and M4 measurements](https://huggingface.co/sr29/Mage-VL-mlx-4bit)
