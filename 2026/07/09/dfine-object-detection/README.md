# D-FINE Object Detection

D-FINE の ONNX モデルを使い、複数の一般物体が写る 1 枚の画像に対して
物体検出を行い、検出結果と推論時間を確認します。

## Purpose

本検証で明らかにしたい問いは次のとおりです。

- D-FINE の COCO 事前学習済み ONNX モデルで、机上の一般物体をどの程度検出できるか
- 640x640 入力、CPU 実行時の 1 回あたりの推論時間はどの程度か
- 検出された bounding box を元画像座標に戻して可視化できるか

評価は 1 枚の固定画像に対して、score threshold 0.5 を設定して行います。

## Input

検証には以下の画像を使用します（リポジトリルートから相対参照）。

```text
assets/jpg/object_detection_desk_scene.png
```

この画像は、机上に laptop、cell phone、cup、bottle、book、chair などが
写るように生成したものです。共有アセットとして取得します。

## Model and preprocessing

[D-FINE](https://huggingface.co/onnx-community/dfine_s_coco-ONNX) の
COCO 事前学習済み ONNX モデルを使用します。

```text
model: https://huggingface.co/onnx-community/dfine_s_coco-ONNX/resolve/a3cf03147a9b86c78475139115c8ac142577352d/onnx/model.onnx
model SHA-256: cd8a49a945feda6d28c6304ae8ae85c2759ba1d78a5a83a22c5ce8db82ef7238
config: https://huggingface.co/onnx-community/dfine_s_coco-ONNX/resolve/a3cf03147a9b86c78475139115c8ac142577352d/config.json
config SHA-256: 9338ef3863d6e95627d4ab06009fa85b1dd523b346b5c3595de2b08862136e99
input: RGB image, resized to 640x640, float32, 0.0-1.0
outputs: logits, pred_boxes
```

初回実行時に `model.onnx` と `config.json` を lab directory 内へ
ダウンロードし、SHA-256 を検証します。検証済みファイルは次回以降再利用します。

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- 初回実行時にインターネット接続（モデルファイルのダウンロード用）
- 共有アセットの取得

リポジトリルートから実行します。

```sh
make download-test-assets
mise -C 2026/07/09/dfine-object-detection run
```

実行すると、検出結果を標準出力へ表示し、bounding box を描画した画像を
`output_detections.png` として保存します。この出力画像は Git 管理しません。

## Observed results

Mac Studio (Apple M4 Max) で実行した結果は次のとおりでした。

```text
--- Input ---
Image:      /Users/kiarina/src/github.com/kiarina/labs/assets/jpg/object_detection_desk_scene.png
Resolution: 1536x1024
Threshold:  0.50

--- Detections ---
Rank | Label            | Score | BBox xyxy
--------------------------------------------------------
   1 | laptop           | 0.970 | (177, 116, 910, 690)
   2 | cup              | 0.965 | (870, 326, 1089, 520)
   3 | chair            | 0.961 | (5, 80, 543, 446)
   4 | bottle           | 0.950 | (1122, 74, 1273, 506)
   5 | cell phone       | 0.947 | (329, 700, 686, 918)
   6 | pottedplant      | 0.937 | (1302, 2, 1535, 466)
   7 | book             | 0.916 | (930, 501, 1521, 838)
   8 | book             | 0.893 | (878, 614, 1519, 962)
   9 | diningtable      | 0.836 | (0, 240, 1533, 1012)
  10 | vase             | 0.543 | (1456, 252, 1535, 465)

Detection count: 10

--- Inference Speed Benchmark (Iterations: 20) ---
Average time: 127.60 ms
Min time:     119.11 ms
Max time:     170.92 ms
Std dev:      10.98 ms
```

Bounding box を描画した画像は `output_detections.png` に保存されます。
この画像は検証出力のため Git 管理しません。

### Verification environment

- machine: Mac Studio (Apple M4 Max)
- OS: macOS 26.5.1, arm64
- Python: 3.12.10
- OpenCV: 5.0.0
- ONNX Runtime: 1.27.0
- NumPy: 2.5.1

## Interpretation and limitations

主要な対象として期待した laptop、cup、chair、bottle、cell phone、book は
高い score で検出されました。さらに、背景の植物や鉢、机も COCO ラベルに
対応する `pottedplant`、`vase`、`diningtable` として検出されています。

一方で、この検証は 1 枚の生成画像に対する結果であり、一般的な検出精度を
示すものではありません。生成画像は物体同士の重なりが少なく、照明条件も
比較的よいため、実環境の写真や小さい物体、強い遮蔽がある画像では結果が
変わる可能性があります。また、後処理として NMS は実装していないため、
画像によっては近い位置の重複検出が残る可能性があります。
