# CLAP ONNX environmental sound grouping

CLAP の audio encoder を ONNX Runtime で動かし、環境音 embedding の近傍が
意味的なカテゴリと一致するかを ESC-50 で検証します。

## Purpose

明らかにしたい問いは次のとおりです。

- CLAP ONNX から 512 次元の正規化 embedding を安定して生成できるか
- 別録音の同一クラスが cosine similarity の最近傍になるか
- 細分類を外した場合も、音が 5 つの大分類の近くにまとまるか

評価は ESC-50 fold 1 の各クラス 1 音を参照集合、fold 5 の各クラス 1 音を
問い合わせ集合とする、学習なしの 1-nearest-neighbor です。50 クラスの
top-1 / top-5 accuracy と、5 大分類の top-1 accuracy を報告します。

## Input

[ESC-50](https://github.com/karolpiczak/ESC-50) は 5 秒の環境音 2,000 本、
50 クラスからなる公開データセットです。本検証は各 fold からファイル名順で
最初の 1 本を選ぶため、合計 100 本だけを GitHub からダウンロードします。
dataset revision は `33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6` に固定します。
ESC-50 全体は CC BY-NC、ESC-10 subset は CC BY です。本検証は ESC-50 全
50 クラスを使用するため、非商用条件に従う必要があります。

選択した WAV、metadata、結果は `data/` と `output/` に置き、Git では管理
しません。

## Model and preprocessing

[Hugging Face の `laion/clap-htsat-unfused`](https://huggingface.co/laion/clap-htsat-unfused)
から checkpoint をダウンロードし、audio encoder、projection layer、
L2 normalization を含む `model.onnx` を生成します。checkpoint revision は
`84bcbbd1d619e407a8216371ddef36e458d95d93`、export は PyTorch 2.8.0、
Transformers 4.57.3、ONNX opset 18 に固定しています。

```text
SHA-256: b23099962830b1afa5398efbb6f5321ef8f63f8fcf93f5019837c47118a8a1c5
inputs: input_features [batch, 1, 1001, 64], is_longer [batch, 1]
output: embeddings [batch, 512]
```

前処理は checkpoint の `preprocessor_config.json` に合わせて NumPy で
実装しています。

- 48 kHz mono
- 10 秒（5 秒音声を `repeatpad`）
- FFT 1,024、hop length 480
- 50 Hz–14 kHz、64-bin HTK mel filter bank
- log-mel spectrogram
- cosine similarity（embedding を L2 normalize）

この ONNX は audio encoder のみなので、CLAP の text encoder を使う
zero-shot classification ではありません。

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- [FFmpeg](https://ffmpeg.org/)
- 初回実行時にインターネット接続
- 約 2 GB の空き容量（Python 環境、checkpoint cache、ONNX、WAV 100 本）

リポジトリルートから実行します。

```sh
mise -C 2026/07/06/clap-onnx-esc50 run
```

初回は Hugging Face から固定 revision の checkpoint を取得し、lab 内に
`model.onnx` を生成してから評価します。2 回目以降は生成済み ONNX の構造と
SHA-256 を検証して再利用します。checkpoint は Hugging Face の標準 cache
（通常は `~/.cache/huggingface/hub/`）に保存されます。

`model.onnx`、データ、JSON report は `.gitignore` の対象です。最初から
生成し直す場合は `model.onnx` を削除して同じコマンドを実行します。

## Observed results

Mac Studio (Apple M4 Max) でウォームアップなしの 1 回の実行結果は次のとおり
でした。

```text
fine accuracy@1:   45/50 = 90%
fine accuracy@5:   50/50 = 100%
coarse accuracy@1: 47/50 = 94%
100 clips elapsed: 5.458 s
seconds per clip:  0.055 s
```

細分類 top-1 の 5 件の誤りは次のとおりでした。

```text
actual             nearest            cosine similarity
crickets           frog               0.690
footsteps          door_wood_knock     0.603
drinking_sipping   brushing_teeth      0.492
mouse_click        keyboard_typing     0.616
airplane           wind               0.717
```

このうち `drinking_sipping → brushing_teeth` と
`mouse_click → keyboard_typing` は同じ大分類内でした。それ以外の 3 件が
大分類でも誤りです。fine top-5 は全 50 件で正解クラスを含みました。

時間は 100 ファイルの FFmpeg decode、NumPy 前処理、ONNX 推論、L2 正規化を
含み、モデル初期化とダウンロードは含みません。単発の参考値であり、厳密な
ベンチマークではありません。

### Verification environment

- machine: Mac Studio (Mac16,9)
- chip: Apple M4 Max
- OS: macOS 26.5.1 (25F80), arm64
- Python: 3.12.11
- NumPy: 2.5.1
- ONNX Runtime: 1.27.0
- execution provider: CPUExecutionProvider

## Interpretation and limitations

観測した 90% の fine accuracy@1 と 94% の coarse accuracy@1 から、この
限定された入力では CLAP embedding が環境音の意味カテゴリをよく保持して
います。ただし、これは固定された 50 個の参照音に対する最近傍検索であり、分類器の学習や
5-fold cross-validation ではありません。各クラス 1 個だけを参照するため、
録音固有の差に強く影響されます。また CLAP の学習データと ESC-50 の重複は
調査しておらず、未知データへの汎化性能を示す評価ではありません。

ESC-50 には、元音源のクラス依存な前処理による情報漏洩の可能性が公式に
明記されています。さらに、この検証の NumPy 前処理が Hugging Face の
`ClapFeatureExtractor` と数値的に完全一致することは未確認です。
