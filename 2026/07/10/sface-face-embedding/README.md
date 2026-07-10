# SFace face embedding dataset comparison

OpenCV Zoo の SFace モデルを使い、顔画像から 128 次元の embedding を生成し、
データセット条件によって同一人物の近傍検索結果がどう変わるかを比較します。

## Purpose

本検証で明らかにしたい問いは次のとおりです。

- SFace の ONNX モデルから 128 次元の L2 正規化 embedding を生成できるか
- 同一人物の別画像が 1-nearest-neighbor で最近傍になるか
- 同一人物ペアと別人物ペアの cosine similarity に差が出るか
- SFace が想定する入力に近いカラー・整列済み顔 crop では結果が改善するか

評価は各データセットから 40 人 x 10 枚を取り、各人物の前半 5 枚を参照集合、
後半 5 枚を問い合わせ集合にした、学習なしの最近傍検索で行います。
各データセット 200 query の top-1 / top-5 accuracy を報告します。

## Input

比較には次の 2 つのデータセットを使用します。

[Olivetti Faces](https://ndownloader.figshare.com/files/5976027) は 40 人、
各 10 枚、合計 400 枚の 64x64 grayscale 顔画像からなる軽量なデータセットです。
配布ファイルを初回実行時に `data/olivetti_faces.mat` へダウンロードし、
SHA-256 を検証してから使用します。

```text
dataset: https://ndownloader.figshare.com/files/5976027
dataset SHA-256: b612fb967f2dc77c9c62d3e1266e0c73d5fca46a4b8906c18e454d41af987794
images: 400
resolution: 64x64 grayscale
people: 40
images per person: 10
```

[Labeled Faces in the Wild](https://vis-www.cs.umass.edu/lfw/) は
実環境に近い顔認識・顔照合用のデータセットです。本検証では
`sklearn.datasets.fetch_lfw_people` で funneled 版のカラー画像を
`data/lfw/` にダウンロードし、20 枚以上ある人物のうち固定順で 40 人を選び、
各人物の先頭 10 枚だけを使います。

```text
dataset loader: sklearn.datasets.fetch_lfw_people
archive: https://ndownloader.figshare.com/files/5976015
archive SHA-256: b47c8422c8cded889dc5a13418c4bc2abbda121092b3533a83306f90d900100a
selected images: 400
selected resolution: 125x94 RGB
selected people: 40
selected images per person: 10
```

ダウンロードしたデータセットと出力 JSON は `data/` と `output/` に置き、
Git では管理しません。LFW は展開後に約 395 MB 使用します。

## Model and preprocessing

[SFace](https://github.com/opencv/opencv_zoo/tree/main/models/face_recognition_sface)
は OpenCV Zoo で公開されている顔認識モデルです。本検証では
`face_recognition_sface_2021dec.onnx` を使用します。

```text
model: https://media.githubusercontent.com/media/opencv/opencv_zoo/47534e27c9851bb1128ccc0102f1145e27f23f98/models/face_recognition_sface/face_recognition_sface_2021dec.onnx
model SHA-256: 0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79
input: aligned BGR face crop, 112x112
output: 128-dimensional embedding
```

入力画像は以下の手順で処理します。

- grayscale または RGB 画像を uint8 にそろえる
- 112x112 に bilinear resize
- grayscale は BGR へ、RGB は BGR へ変換
- `cv2.FaceRecognizerSF.feature` で embedding を取得
- cosine similarity で比較するため L2 normalize

本検証では顔検出や追加のランドマーク alignment は行いません。Olivetti Faces は
小さい grayscale crop、LFW は funneled 版のカラー crop として扱います。

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- 初回実行時にインターネット接続（モデルとデータセットのダウンロード用）
- 約 500 MB の空き容量（Python 環境、モデル、データセット）

リポジトリルートから実行します。

```sh
mise -C 2026/07/10/sface-face-embedding run
```

初回は `models/` に ONNX モデル、`data/` にデータセットをダウンロードします。
2 回目以降はダウンロード済みファイルを再利用します。詳細な結果は
`output/olivetti_report.json`、`output/lfw_report.json`、比較用の
`output/summary.json` に保存します。

## Observed results

Mac Studio (Apple M4 Max) で実行した結果は次のとおりでした。

```text
Dataset                         | Top-1 | Top-5 | Pos cosine | Neg cosine | sec/image
-------------------------------------------------------------------------------------
Olivetti Faces                  | 0.800 | 0.920 |      0.722 |      0.577 |    0.0057
LFW people, funneled color crop | 0.820 | 0.945 |      0.463 |      0.228 |    0.0058
```

### Verification environment

- machine: Mac Studio (Apple M4 Max)
- OS: macOS 26.5.1, arm64
- Python: 3.12.10
- OpenCV: 5.0.0
- NumPy: 2.5.1
- SciPy: 1.18.0
- scikit-learn: 1.9.0
- Pillow: 12.3.0

## Interpretation and limitations

Olivetti Faces では top-1 accuracy が 80%、top-5 accuracy が 92% となり、
小さい grayscale crop でも SFace embedding の近傍に同一人物の画像が一定程度
集まることを確認できました。

LFW の funneled color crop では top-1 accuracy が 82%、top-5 accuracy が 94.5%
となり、Olivetti より少し高い結果でした。特に同一人物ペアと別人物ペアの平均
cosine similarity の差は、Olivetti の 0.145 に対して LFW は 0.235 と大きく、
SFace が想定するカラー顔 crop に近い条件の方が人物ごとの分離が明確でした。

ただし、LFW でも 18% の query は top-1 で別人物を最近傍としており、完全な識別には
届いていません。本検証では顔検出や追加のランドマーク alignment を行わず、
データセットの crop をそのまま 112x112 に resize しています。SFace の本来の評価に
近づけるには、同じ検出器と alignment 条件で顔を切り出す検証が必要です。

また、評価は各人物の前半 5 枚を参照、後半 5 枚を query とする固定分割の
1-nearest-neighbor です。学習済み分類器や cross-validation ではないため、一般的な
顔認識性能を示すものではありません。実行時間も各データセット 400 枚を一度処理した
単発の参考値であり、厳密なベンチマークではありません。
