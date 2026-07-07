# YAMNet audio tagging on ESC-50

YAMNet の TFLite モデルを使い、環境音データセット ESC-50 に対する
音声タギング結果が ESC-50 のカテゴリとどの程度対応するかを検証します。

## Purpose

明らかにしたい問いは次のとおりです。

- YAMNet TFLite を Python から再現可能に実行できるか
- YAMNet の 521 個の AudioSet ラベルを ESC-50 の 50 カテゴリに対応させたとき、
  正解カテゴリが上位候補に入るか
- ESC-50 の 5 つの大分類では、細分類より安定した結果になるか
- 5 秒音声 2,000 本の逐次推論にどの程度の時間がかかるか

評価は学習なしで行います。各音声について YAMNet の frame scores を clip 単位に
集約し、あらかじめ定義した ESC-50 category と YAMNet label の対応表に基づいて
category score を作ります。最も score が高い category を予測とし、fine
accuracy@1 / @3 / @5 と coarse accuracy@1 を報告します。

## Input

[ESC-50](https://github.com/karolpiczak/ESC-50) は 5 秒の環境音 2,000 本、
50 クラスからなる公開データセットです。本検証では全 2,000 本を使用します。
dataset revision は `33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6` に固定します。

ESC-50 全体は CC BY-NC、ESC-10 subset は CC BY です。本検証は ESC-50 全
50 クラスを使用するため、非商用条件に従う必要があります。

データセット archive、展開後の WAV、モデル、class map、結果は `data/`、
`models/`、`output/` に置き、Git では管理しません。

## Model and preprocessing

[YAMNet](https://www.tensorflow.org/hub/tutorials/yamnet) は AudioSet の
521 audio event classes を予測する音声分類モデルです。本検証では TensorFlow
Hub で公開されている TFLite 版を使用します。

```text
model: https://tfhub.dev/google/lite-model/yamnet/classification/tflite/1?lite-format=tflite
model SHA-256: 10c95ea3eb9a7bb4cb8bddf6feb023250381008177ac162ce169694d05c317de
class map revision: 5c597f85268743140854f0e670f2175e8668553a
class map SHA-256: cdf24d193e196d9e95912a2667051ae203e92a2ba09449218ccb40ef787c6df2
input: 1-D float32 waveform, 16 kHz mono
output: frame scores [frames, 521]
```

音声は FFmpeg で 16 kHz mono float32 PCM に変換し、そのまま TFLite モデルへ
入力します。frame scores は既定では mean で集約します。`--aggregation max`
を指定すると最大値集約に切り替えられます。

ESC-50 と YAMNet はラベル体系が一致しないため、評価には手作業で定義した対応表を
使います。たとえば `dog` は `Dog` と `Bark`、`keyboard_typing` は `Typing` と
`Computer keyboard` に対応させます。一部のカテゴリは完全一致する YAMNet ラベルを
持たないため、結果はこの対応表に依存します。

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- [FFmpeg](https://ffmpeg.org/)
- 初回実行時にインターネット接続
- 数百 MB 程度の空き容量

リポジトリルートから実行します。

```sh
mise -C 2026/07/07/yamnet-esc50-audio-tagging run
```

短い動作確認だけを行う場合は、lab ディレクトリで次を実行します。

```sh
uv run python main.py --folds 1 --limit-per-class 1
```

初回はモデル、class map、ESC-50 archive をウェブから取得します。2 回目以降は
ダウンロード済みファイルの SHA-256 を検証して再利用します。

## Observed results

Mac Studio (Apple M4 Max) でウォームアップなしの 1 回の実行結果は次のとおり
でした。

```text
all clips:
  fine accuracy@1:   1209/2000 = 60.45%
  fine accuracy@3:   1583/2000 = 79.15%
  fine accuracy@5:   1709/2000 = 85.45%
  coarse accuracy@1: 1574/2000 = 78.70%

direct label mapping categories:
  fine accuracy@1:   1103/1600 = 68.94%
  fine accuracy@3:   1360/1600 = 85.00%
  fine accuracy@5:   1448/1600 = 90.50%
  coarse accuracy@1: 1328/1600 = 83.00%

2000 clips elapsed: 55.382 s
seconds per clip:   0.028 s
```

`direct label mapping categories` は、ESC-50 category にかなり直接対応する
YAMNet label があると判断した 40 category だけを集計したものです。
たとえば `dog`、`cat`、`rain`、`keyboard_typing`、`chainsaw` などは含め、
`insects`、`drinking_sipping`、`can_opening`、`washing_machine` などは除いて
います。

時間は 2,000 ファイルの FFmpeg decode、TFLite 推論、frame score の mean 集約、
ESC-50 category score の計算を含み、モデルとデータのダウンロードは含みません。
単発の参考値であり、厳密なベンチマークではありません。

### Verification environment

- machine: Mac Studio (Apple M4 Max)
- OS: macOS 26.5.1, arm64
- Python: 3.12.11
- NumPy: 2.5.1
- ai-edge-litert: 2.1.6
- aggregation: mean

## Interpretation and limitations

この検証は YAMNet の 521 ラベルを ESC-50 の 50 カテゴリへ写像した上での評価です。
そのため、YAMNet が正しく音響イベントを検出していても、対応表に含めていない近い
ラベルを強く出した場合は不正解になります。逆に、広いラベルが偶然 ESC-50 のカテゴリ
score を押し上げることもあります。

たとえば ESC-50 の `hen` は YAMNet の `Chicken, rooster` と `Cluck` に対応させて
いますが、`rooster` も `Chicken, rooster` を共有します。このようなカテゴリ間では、
音響的に近い予測が fine accuracy では誤りとして数えられます。

また、学習や cross-validation は行いません。既存の事前学習済みモデルを固定し、
ESC-50 全 2,000 本を 1 回ずつ推論した観測結果をまとめる検証です。ESC-50 には、
元音源のクラス依存な前処理による情報漏洩の可能性が公式に明記されています。
