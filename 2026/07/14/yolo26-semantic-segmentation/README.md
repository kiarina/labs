# YOLO26 semantic segmentation on Apple Silicon

YOLO26n semantic segmentation を同じ固定画像に対して PyTorch CPU と
ONNX Runtime CPU から実行し、速度と画素単位の出力差を比較します。

## What this model does

このモデルが行うのは、**画像のすべての画素を、都市道路に関係する19種類の
どれかに分類すること**です。出力は物体名の一覧や bounding box ではなく、入力画像と
同じ縦横サイズの class map です。例えば道路の全画素には `road`、空には `sky`、
自動車には `car` という class ID が入ります。

利用できるクラスは次の19種類に固定されています。

```text
road, sidewalk, building, wall, fence, pole, traffic light, traffic sign,
vegetation, terrain, sky, person, rider, car, truck, bus, train,
motorcycle, bicycle
```

したがって、道路の走行可能領域、歩道、車両、人、標識、建物、植生などを画素単位で
分ける都市道路の scene parsing に利用できます。自動運転向け画像の前処理や、道路と
歩道の面積計測、領域別のぼかし・色変更といった処理へつなげられます。

一方、この checkpoint は一般物体認識モデルではありません。`laptop`、`book`、
`cup` などのクラスを持たないため、この室内画像を正しく説明することはできません。
また、同じクラスの自動車が複数あっても個体を分けず、物体数、bounding box、OCR結果、
画素ごとの信頼度もこの出力からは得られません。

## Purpose

本検証で明らかにしたい問いは次のとおりです。

- YOLO26n semantic segmentation の公式 checkpoint を Apple Silicon 上で実行し、
  ONNX へ変換できるか
- 入力条件を揃えた PyTorch と ONNX Runtime の class map はどの程度一致するか
- ウォームアップ後の推論・後処理・全処理時間はどの程度か
- Cityscapes で学習したモデルが都市道路の生成画像をどのように領域分割するか

固定画像 1 枚について、両 backend の画素一致率、予測クラスごとの領域比率と IoU、
3 回のウォームアップ後 10 回の処理時間、出力画像の目視結果を記録します。

## Input

検証には次の共有画像だけを使用します（リポジトリルートから相対参照）。

```text
tests/assets/jpg/street_scene_1774x887_287kb.jpg
resolution: 1774x887
SHA-256: d5c865f452599311fbbfd0c132bb4f8b7ade4dd88f0c8ac14ce136490ea53a2e
```

車道、歩道、建物、塀、フェンス、信号、標識、植生、空、自動車、バス、歩行者、
自転車の rider、駐車した motorcycle が写る昼間の都市道路の生成画像です。
Cityscapes の想定 domain に近く、複数の学習クラスを目視確認できる構図にしています。

## Model and conditions

[Ultralytics の semantic segmentation](https://docs.ultralytics.com/tasks/semantic/)
は画像の全画素へ class ID を割り当てます。個々の物体を分離する instance
segmentation とは異なり、同じクラスの画素は一つの class map にまとめられます。

本検証の `yolo26n-sem.pt` は Cityscapes で事前学習された 19 クラスの公式モデルです。
公式値は Cityscapes validation、1024x2048 入力で mIoU 78.3 ですが、本検証は
正解 mask のない対象外画像を 640x640 入力で処理するため、その値とは比較しません。

```text
model: yolo26n-sem.pt
source: https://github.com/ultralytics/assets/releases/download/v8.4.0/yolo26n-sem.pt
size: 3,487,283 bytes
SHA-256: f3f293cca764de1f93044030d8d5612de9c5ffbf37c9c8ea1b69418b73038999
PyTorch input: 1x3x640x640
ONNX input: images, float32, 1x3x640x640
ONNX output: output0, uint8 class IDs, 1x640x640
ONNX opset: 18
provider: CPUExecutionProvider
```

PyTorch と ONNX で前処理を揃えるため、両方とも `imgsz=640`、`rect=False` とします。
`rect=False` は元画像を縦横比を維持したまま 640x640 の領域へ letterbox する条件です。
ONNX は `simplify=False` で公式 exporter から生成し、Ultralytics の同じ predict API で
前処理と元解像度への復元を行います。モデル初期化、ファイル読み込み、可視化画像の
保存は benchmark に含めません。

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- 初回実行時にインターネット接続（モデルと共有アセットの取得用）

リポジトリルートから実行します。

```sh
mise -C 2026/07/14/yolo26-semantic-segmentation run
```

task は最初に `mise run //:test-assets:download` を実行します。初回は checkpoint を
ダウンロードして SHA-256 を検証し、ONNX を生成します。次の比較画像も生成します。

```text
output_pytorch.png
output_onnx.png
output_disagreement.png
output_explanation.png
```

モデル、ONNX、出力画像は検証生成物のため Git 管理しません。差分画像では
PyTorch と ONNX の class ID が異なる画素を赤く表示します。
`output_explanation.png` は元画像と ONNX の色分け結果を並べ、実際に予測された
クラスの色、名前、画素割合を同じ画像内に表示します。

## Observed results

Apple M1 Max の CPU 上で PyTorch checkpoint を ONNX opset 18 へ変換し、
ONNX Runtime `CPUExecutionProvider` で推論できました。

`output_explanation.png` では左に元画像、右に50%透過した class map、下部に凡例を
配置しました。色は Cityscapes のクラス色に合わせています。道路、歩道、建物、
植生、空といった大きな領域に加え、人、rider、車、motorcycle、bicycle などの
小さな対象も画像上で確認できます。

同じ画像を3回ウォームアップした後、10回処理した結果は次のとおりです。

| backend / stage | mean | min | max | std dev |
| --- | ---: | ---: | ---: | ---: |
| PyTorch preprocessing | 0.93 ms | 0.89 ms | 1.04 ms | 0.04 ms |
| PyTorch inference | 28.83 ms | 26.39 ms | 30.31 ms | 1.02 ms |
| PyTorch postprocessing | 236.07 ms | 233.19 ms | 239.70 ms | 1.67 ms |
| PyTorch wall time | 266.00 ms | 264.44 ms | 270.02 ms | 1.69 ms |
| ONNX preprocessing | 1.01 ms | 0.91 ms | 1.24 ms | 0.10 ms |
| ONNX inference | 25.67 ms | 24.32 ms | 26.91 ms | 0.88 ms |
| ONNX postprocessing | 0.72 ms | 0.60 ms | 1.11 ms | 0.15 ms |
| ONNX wall time | 27.55 ms | 26.06 ms | 28.82 ms | 0.95 ms |

ONNX の推論部分は PyTorch の約 0.89 倍、全処理時間は約 0.10 倍でした。
大きな差は推論本体より後処理にありました。PyTorch 経路では class logits を元画像
サイズへ拡大してから class ID を決める一方、export された ONNX は 640x640 の
class ID map を出力し、それを元画像へ戻すためです。この違いにより、速度だけでなく
境界の画素値にも小さな差が生じます。

両 backend の class ID が一致した画素は **99.3129%**、異なった画素は
**0.6871%** でした。予測された16クラスの比較は次のとおりです。

| class | PyTorch area | ONNX area | IoU between backends |
| --- | ---: | ---: | ---: |
| road | 21.27% | 21.22% | 99.52% |
| sidewalk | 10.38% | 10.39% | 98.48% |
| building | 16.28% | 16.30% | 98.99% |
| wall | 3.05% | 3.05% | 97.16% |
| fence | 4.18% | 4.17% | 98.32% |
| pole | 1.62% | 1.61% | 88.15% |
| traffic light | 0.03% | 0.04% | 88.03% |
| traffic sign | 0.29% | 0.29% | 93.30% |
| vegetation | 26.52% | 26.54% | 98.85% |
| terrain | 0.02% | 0.02% | 82.92% |
| sky | 8.94% | 8.97% | 99.15% |
| person | 0.90% | 0.90% | 96.20% |
| rider | 0.21% | 0.21% | 94.61% |
| car | 5.11% | 5.12% | 98.67% |
| motorcycle | 0.74% | 0.74% | 95.68% |
| bicycle | 0.44% | 0.44% | 94.24% |

### Failed attempt

最初の比較では `rect` を指定せず、画素一致率は 98.9648% でした。PyTorch の
native model は入力の最小 padding を使う一方、固定 shape の ONNX は 640x640 の
padding を使い、同じ `imgsz=640` でも実入力条件が揃っていませんでした。
両方を `rect=False` に固定すると 99.3129% まで改善したため、最初の値は backend
差ではなく主に前処理条件の差と判断しました。

### Verification environment

- machine: MacBook Pro (Apple M1 Max, arm64)
- OS: macOS 26.5.2
- Python: 3.12.10
- Ultralytics: 8.4.95
- PyTorch: 2.13.0
- ONNX: 1.22.0
- ONNX Runtime: 1.27.0
- OpenCV: 5.0.0
- NumPy: 2.5.1

## Interpretation and limitations

ONNX Runtime への export は成功し、同じ前処理条件では PyTorch と 99.5% を超える
画素が一致しました。差分は主に予測領域の境界にあり、640x640 の class map を元画像へ
拡大する際の処理順序と整合します。ONNX はこの条件で推論本体も少し速く、特に class
ID map を直接出力することで後処理が大幅に短くなりました。

新しい入力は Cityscapes の想定に近く、道路、歩道、建物、壁、フェンス、植生、空、
人物、rider、車、motorcycle、bicycle を目視上も妥当な位置へ割り当てました。
19クラス中16クラスが出力され、室内画像で見られた大きな domain mismatch は
解消しました。一方、画像奥にバスが写っているにもかかわらず `bus` は出力されず、
小さい遠方物体の取りこぼしがありました。`truck` と `train` は入力画像に存在しません。

本検証は正解 mask のない生成画像1枚、入力640、CPU、1台の Apple Silicon Mac に
限られます。Cityscapes validation の mIoU、異なる解像度、MPS、CoreML、量子化、
消費メモリ、実写の道路画像、異なる道路画像は未確認です。また Ultralytics の source
code と model は AGPL-3.0 と Enterprise のデュアルライセンスで提供されるため、
本検証を製品へ組み込む場合は
[Ultralytics のライセンス説明](https://www.ultralytics.com/license)を参照し、
用途に合う条件を別途確認する必要があります。本リポジトリには checkpoint、ONNX、
Ultralytics 自体を収録せず、実行時に取得・生成します。
