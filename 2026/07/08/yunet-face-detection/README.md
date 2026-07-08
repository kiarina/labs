# YuNet Face Detection

YuNet の ONNX モデルを使い、1枚の多人数画像（many_face）に対する顔検出の推論速度と、解像度変化に対するロバスト性（スケール耐性）を検証します。

## Purpose

本検証で明らかにしたい問いは次のとおりです。

- OpenCV Zoo で提供される YuNet INT8 ONNX モデルを用いた場合、1280x720 の画像に対する 1回あたりの推論時間はどの程度か
- 同一の画像に対して入力解像度（スケール）を 0.25 倍から 2.0 倍まで変動させた際、検出される顔の数や最高スコアはどう変化するか

評価は 1枚の固定画像（many_face_1280x720_275kb.jpg）に対して、スコア閾値 0.6、NMS 閾値 0.3 を設定して行います。

## Input

検証には以下の画像を使用します（リポジトリルートから相対参照）。
`tests/assets/jpg/many_face_1280x720_275kb.jpg` (解像度: 1280x720)

データセットのアーカイブや他の画像は使用しません。

## Model and preprocessing

[YuNet](https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet) は軽量で高速な顔検出モデルです。本検証では OpenCV Zoo で公開されている INT8 量子化 ONNX モデルを使用します。

```text
model: https://media.githubusercontent.com/media/opencv/opencv_zoo/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_detection_yunet/face_detection_yunet_2023mar_int8bq.onnx
model SHA-256: 49f000ec501fef24739071fc7e68267d32209045b6822c0c72dce1da25726f10
input: 1-D BGR image (dynamic resolution)
output: bounding box, score, 5-point landmarks
```

OpenCV の `cv2.FaceDetectorYN` を用いて画像を直接読み込み推論します。
画像はリサイズによりスケールを変え、都度 `setInputSize` で入力解像度を更新して評価します。

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- OpenCV Python
- 初回実行時にインターネット接続（モデルファイルのダウンロード用）

リポジトリルートから実行します。

```sh
mise -C 2026/07/08/yunet-face-detection run
```

初回はモデル（ONNX）をウェブから取得します。2回目以降はダウンロード済みファイルの SHA-256 を検証して再利用します。

## Observed results

Mac Studio (Apple M4 Max) でウォームアップ後に実行した結果は次のとおりでした。

```text
--- Inference Speed Benchmark (Iterations: 100) ---
Average time: 9.21 ms
Min time:     8.03 ms
Max time:     10.47 ms
Std dev:      0.55 ms

--- Scale Variance Experiment ---
 Scale |    Resolution |  Faces | Max Score | Min Score
-------------------------------------------------------
  0.25 |       320x180 |      6 |     0.871 |     0.638
  0.50 |       640x360 |     26 |     0.910 |     0.611
  0.75 |       960x540 |     32 |     0.920 |     0.622
  1.00 |      1280x720 |     38 |     0.930 |     0.630
  1.50 |     1920x1080 |     43 |     0.937 |     0.652
  2.00 |     2560x1440 |     52 |     0.939 |     0.605
```

### Verification environment

- machine: Mac Studio (Apple M4 Max)
- OS: macOS 26.5.1, arm64
- Python: 3.12.11
- OpenCV: 5.0.0.93

## Interpretation and limitations

1280x720 サイズの画像に対する 1 回あたりの推論時間は平均 9.21 ms と非常に高速であることが確認できました。

スケール検証の結果から、入力解像度が大きくなるにつれて検出される顔の数（Faces）が明確に増加しています。これは、元画像において非常に小さく写っている顔が、高解像度化（スケール 1.5 や 2.0）によって YuNet が捉えられるサイズに拡大されたためと考えられます。
反対に 0.25 倍（320x180）の解像度では特徴が潰れてしまい、6人の顔しか検出できませんでした。

最大スコアはスケールが大きくなるにつれて微増傾向にありますが、最小スコアには一定の傾向が見られません（常に 0.6 付近）。これは、解像度が上がることで新たに検出されるようになった「小さく不鮮明な顔」が低いスコアを出力しているためと推測されます。

この検証はあくまで特定の 1 枚の画像（`many_face_1280x720_275kb.jpg`）を用いた結果であり、様々な環境・照明条件を含むデータセット全体での精度を示すものではありません。また、ONNX のグラフ最適化等に依存するため環境によっては推論速度が異なる可能性があります。
