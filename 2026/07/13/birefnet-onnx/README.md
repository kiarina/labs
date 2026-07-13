# BiRefNet ONNX background removal

BiRefNet の ONNX モデルを ONNX Runtime から実行し、固定画像 1 枚の背景を
透過させた PNG を生成して、CPU 上の処理時間と結果を確認します。

## Purpose

本検証で明らかにしたい問いは次のとおりです。

- BiRefNet の公式 ONNX モデルを Python の ONNX Runtime から実行できるか
- 人物と細い髪を含む画像で、背景を透過した PNG を生成できるか
- Apple Silicon の CPU 上で、推論と前後処理にどの程度の時間がかかるか

評価には固定画像 1 枚のみを使い、出力画像の目視確認、alpha 値の分布、
ウォームアップ後 10 回の推論時間を記録します。

## Input

検証には次の共有画像だけを使用します（リポジトリルートから相対参照）。

```text
tests/assets/jpg/removebg_1536x1024_141kb.jpg
resolution: 1536x1024
SHA-256: d3d362b876936c57cfaf61eedd0ada05fd4950483ab79502aa5a67ded4a6b910
```

## Model and processing

[BiRefNet](https://github.com/ZhengPeng7/BiRefNet) は、高解像度の dichotomous
image segmentation（前景と背景の 2 領域への分割）のためのモデルです。
本検証では、公式 GitHub Release の general-purpose な Swin-Tiny 版を使います。

```text
model: BiRefNet-general-bb_swin_v1_tiny-epoch_232.onnx
source: https://github.com/ZhengPeng7/BiRefNet/releases/download/v1/BiRefNet-general-bb_swin_v1_tiny-epoch_232.onnx
size: 224,005,088 bytes
SHA-256: 5600024376f572a557870a5eb0afb1e5961636bef4e1e22132025467d0f03333
input: input_image, float32, 1x3x1024x1024
output: output_image, float32 logits, 1x1x1024x1024
runtime: ONNX Runtime CPUExecutionProvider
```

OpenCV で BGR 画像を読み込み、1024x1024 にリサイズして RGB へ変換し、
ImageNet の平均・標準偏差で正規化します。
[ONNX Runtime の Python API](https://onnxruntime.ai/docs/api/python/api_summary.html) に
従って `onnxruntime.InferenceSession` を作り、`run` に NumPy 配列を渡します。
出力 logits へ sigmoid を適用し、マスクを元画像の 1536x1024 に戻して alpha channel
とした後、BGRA の透過 PNG を OpenCV で保存します。

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- 初回実行時にインターネット接続（モデルと共有アセットの取得用）

リポジトリルートから実行します。

```sh
mise -C 2026/07/13/birefnet-onnx run
```

task は最初に `mise run //:test-assets:download` を実行します。初回は ONNX モデルを
ダウンロードして SHA-256 を検証し、`output_removed_bg.png` を生成します。
モデルと出力画像は検証生成物のため Git 管理しません。

## Observed results

MacBook Pro (Apple M1 Max) の CPU で実行し、人物の背景を透過した
`output_removed_bg.png` を生成できました。出力は 1536x1024、8-bit RGBA PNG で、
alpha channel の最小値は 0、最大値は 255 でした。

1 回目の処理時間は次のとおりです。モデルのダウンロード、SHA-256 検証、
`InferenceSession` の初期化、画像読み込みは含めていません。

```text
--- One-shot processing time ---
Preprocessing:  23.86 ms
Inference:      4699.83 ms
Postprocessing: 6.80 ms
PNG save:       41.07 ms
Total:          4771.56 ms
```

同じ前処理済み入力を使い、3 回のウォームアップ後に 10 回推論した結果です。

```text
--- Inference benchmark (Warmup: 3, Iterations: 10) ---
Average time: 4319.62 ms
Min time:     4206.41 ms
Max time:     4480.35 ms
Std dev:      88.62 ms
```

出力 alpha channel の画素分布は次のとおりでした。

```text
Transparent (alpha=0): 65.92%
Transition (1-254):     9.37%
Opaque (alpha=255):     24.71%
```

### Verification environment

- machine: MacBook Pro (Apple M1 Max, arm64)
- OS: macOS 26.5.1
- Python: 3.12.10
- ONNX Runtime: 1.27.0
- OpenCV: 5.0.0
- NumPy: 2.5.1

## Interpretation and limitations

人物、白い服、髪の主要部分は背景から分離されました。右側へ伸びた細い髪も
多くは alpha mask に残り、半透明画素を使った滑らかな境界が生成されました。

一方、頭頂部や右側の特に細い飛び毛には消えた箇所があり、髪と服の輪郭には
元背景の青色がわずかに残りました。alpha が中間値の画素は 9.37% ありますが、
これは境界の品質を直接表す精度指標ではありません。本検証には正解 mask がなく、
結果の評価は目視確認に限られます。また、明るい屋外で人物が中央に写る 1 枚だけの
結果であり、他の被写体、複雑な背景、低照度、低解像度、複数人物、異なるモデルとの
品質・速度比較は未確認です。
