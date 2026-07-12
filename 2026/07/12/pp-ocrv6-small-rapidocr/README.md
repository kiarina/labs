# PP-OCRv6-small with RapidOCR

RapidOCR の ONNX Runtime バックエンドから PP-OCRv6-small を実行し、
日本語と英語を含む固定画像に対する認識結果と CPU 推論時間を検証します。

## Purpose

本検証で明らかにしたい問いは次のとおりです。

- RapidOCR から PP-OCRv6-small の検出・認識モデルを明示的に選択して実行できるか
- 日本語、英語、数字、記号、縦書き、斜めの文字が混在する画像をどの程度読み取れるか
- Apple Silicon の CPU 上で、モデル初期化を除いた OCR 処理時間はどの程度か

評価は 1 枚の固定画像に対して行い、検出文字列、信頼度、座標、
代表的な 14 文字列の一致状況と、ウォームアップ後 10 回の処理時間を記録します。

## Input

検証には次の共有画像を使用します（リポジトリルートから相対参照）。

```text
tests/assets/jpg/ocr_1448x1086_242kb.jpg
resolution: 1448x1086
SHA-256: 42d9024588f112ab9fbaf69c0e32a95462613c35b9cdbbb1a9c4bc1ff93ab96e
```

室内に掲示された日本語・英語、ホワイトボード、縦書きの本、PC 画面、
小さい連絡先、斜めに置かれた封筒などを含む生成画像です。

## Models and conditions

[PP-OCRv6](https://huggingface.co/blog/PaddlePaddle/pp-ocrv6) は tiny、small、
medium の 3 段階で提供される OCR モデル群です。本検証では約 7.7M parameters の
small を選び、[RapidOCR](https://github.com/RapidAI/RapidOCR) 3.9.1 から実行します。

```text
detection:      PP-OCRv6_det_small.onnx
classification: ch_ppocr_mobile_v2.0_cls_mobile.onnx (RapidOCR default)
recognition:    PP-OCRv6_rec_small.onnx, Japanese language setting
engine:         ONNX Runtime CPUExecutionProvider
warmup:         3 iterations
benchmark:      10 iterations
```

モデルは `rapidocr` wheel に同梱されたものを使用します。PaddleOCR、OpenVINO、
MNN、GPU backend との比較は行いません。

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- 共有アセット取得時のインターネット接続

リポジトリルートから実行します。

```sh
mise -C 2026/07/12/pp-ocrv6-small-rapidocr run
```

task は最初に `mise run //:test-assets:download` を実行します。OCR 結果を標準出力へ
表示し、bounding polygon と認識文字を描画した `output_ocr.jpg` を生成します。
この画像は検証生成物のため Git 管理しません。

## Observed results

40 行が検出され、信頼度の平均は 0.984、最小は 0.883、最大は 1.000 でした。
代表的な 14 文字列のうち 12 件が一致し、2 件に誤認識がありました。
複数の検出行に分割された文字列は、各部分が検出結果に含まれることを確認しています。

主な認識結果は次のとおりです。

```text
Score | Recognized text
------+------------------------------------------------
0.959 | OCR テストルーム
0.985 | 日本語·English·12345
0.947 | ·在庫確認：ノ-ト12冊／ペン24本
0.969 | • Next review: Friday, 3:45 PM
0.999 | 日本語の練習
0.993 | Deep Learning Basics
0.883 | 取极注意
1.000 | FRAGILE
0.998 | The quick brown fox
0.992 | jumps over the lazy dog.
1.000 | 東京都千代田区1-2-3
0.999 | Email: test@example.com
0.996 | TEL 03-1234-5678
```

期待に反した結果も含む代表文字列の確認結果は次のとおりです。

```text
PASS: OCR テストルーム
PASS: Please knock before entering
PASS: 12345
MISS: 在庫確認：ノート12冊／ペン24本
PASS: Next review: Friday, 3:45 PM
PASS: 忘れずに水やり
PASS: Call Ken at 18:00
PASS: 日本語の練習
PASS: Deep Learning Basics
MISS: 取扱注意
PASS: FRAGILE
PASS: 東京都千代田区1-2-3
PASS: test@example.com
PASS: 03-1234-5678
```

速度測定では、モデル初期化と最初の推論を含めず、画像の読み込み後に同じ画像を
OCR pipeline 全体へ入力しました。

```text
--- OCR Speed Benchmark (Iterations: 10) ---
Average time: 839.01 ms
Min time:     758.89 ms
Max time:     890.43 ms
Std dev:      37.32 ms
```

### Verification environment

- machine: Mac Studio (Apple M4 Max, arm64)
- OS: macOS 26.5.1
- Python: 3.12.10
- RapidOCR: 3.9.1
- ONNX Runtime: 1.27.0
- OpenCV: 5.0.0

## Interpretation and limitations

横書きだけでなく、縦書きの「日本語の練習」「Deep Learning Basics」や、
斜めの「東京都千代田区1-2-3」、小さい email と電話番号も認識できました。
1 回の pipeline 処理はこの環境で平均約 839 ms でした。

一方、「ノート」の長音符がハイフンとして扱われて `ノ-ト` となり、
「取扱注意」は `取极注意` と誤認識されました。高い信頼度でも文字列が正しいとは
限りません。また、代表文字列の集計外でも `Project Alpha` が `Project Alpi` と
なりました。信頼度だけで精度を判断できないことが観測されました。

本検証は読みやすい 1 枚の生成画像に対する結果であり、一般的な OCR 精度を示す
ものではありません。手書き、低照度、ぼけ、強い歪み、より小さい文字、異なる
フォントは未確認です。また、処理時間には検出・方向分類・認識・前後処理を含み、
環境や ONNX Runtime の最適化によって変動します。
