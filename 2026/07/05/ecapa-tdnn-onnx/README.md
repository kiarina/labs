# ECAPA-TDNN ONNX speaker grouping

Pyannote Segmentation 3.0 で会話音声を発話単位へ分割し、ECAPA-TDNN の
話者 embedding と cosine similarity を使って同じ話者の発話をまとめる検証です。

## Purpose

2 話者の短い会話について、SCD が切り出した各発話を、話者数をあらかじめ
指定せずに正しい 2 グループへ分けられるか確認します。

明らかにしたい問いは次のとおりです。

- 各発話から一貫した 192 次元の話者 embedding を生成できるか
- 単純な逐次しきい値方式で、同じ話者の 3 発話ずつをまとめられるか
- Apple Silicon の CPUExecutionProvider で実時間より高速に処理できるか

評価では、既知の会話順に対するグループ割当、cosine similarity、embedding の
L2 norm、推論時間と real-time factor (RTF) を確認します。

## Input

共有 test asset の次の音声を使用します。

```text
tests/assets/mp3/conversation_2speaker_14s_16k.mp3
```

2 人が交互に 3 回ずつ発話するため、期待するグループは `1, 3, 5` と
`2, 4, 6` です。

## Models

SCD には Hugging Face の
[`onnx-community/pyannote-segmentation-3.0`](https://huggingface.co/onnx-community/pyannote-segmentation-3.0)
を使用します。

話者 embedding には
[`pranjal-pravesh/ecapa_tdnn_onnx`](https://huggingface.co/pranjal-pravesh/ecapa_tdnn_onnx)
の `ecapa_tdnn.onnx` を使用します。リポジトリの commit とモデルの
SHA-256 を固定しています。

```text
commit: 04c3ffe4fd00b3b7853fd57db44e2e531d4817f2
SHA-256: 245eb5995cfffd74494862dee33da2b00c1c2579eb0c6703847784e9901ed458
input: audio [batch, samples]
output: embedding [1, 1, 192]
```

モデル内部には SpeechBrain の Fbank、InputNormalization、ECAPA-TDNN が
含まれ、生の 16 kHz mono waveform から embedding までを一度に計算します。

## Requirements

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- [FFmpeg](https://ffmpeg.org/)
- `curl`

## Run

リポジトリルートから実行します。

```sh
mise -C 2026/07/05/ecapa-tdnn-onnx run
```

初回実行時に 2 個の ONNX モデルを lab 内へダウンロードします。ECAPA-TDNN
モデルは実行前と推論コード内の両方で SHA-256 を検証し、不一致なら停止します。
モデル、出力 WAV、JSON report は Git の管理対象外です。

既存の `output/` は実行ごとに削除して生成し直します。

```text
output/
├── groups.json
└── segments/
    ├── 1.wav
    ├── 2.wav
    └── ...
```

入力、モデル、出力先、類似度しきい値は変更できます。

```sh
uv run python main.py \
  --audio path/to/audio.mp3 \
  --scd-model path/to/scd.onnx \
  --ecapa-model path/to/ecapa_tdnn.onnx \
  --output path/to/output \
  --similarity-threshold 0.45
```

## Settings and grouping

- sample rate: 16 kHz mono
- embedding dimension: 192
- embedding normalization: L2
- similarity: cosine similarity
- speaker similarity threshold: 0.45
- execution provider: CPUExecutionProvider

発話を時間順に処理し、新しい embedding と各既存グループ内の全 embedding
との最大類似度を求めます。最大値が 0.45 以上ならそのグループへ追加し、
それ未満なら新しいグループを作ります。

## Observed results

Mac Studio (Apple M4 Max) でウォームアップなしの 1 回の実行結果は次のとおり
でした。

```text
audio duration: 14.171s
SCD elapsed: 0.019s
SCD real-time factor: 0.001x
embedding elapsed: 0.114s
embedding real-time factor: 0.008x
similarity threshold: 0.450
segments: 6
groups: 2
1:   0.000s -   1.851s ( 1.851s) group=0 best_score=  new
2:   1.851s -   4.737s ( 2.886s) group=1 best_score=0.095
3:   4.737s -   7.317s ( 2.581s) group=0 best_score=0.459
4:   7.317s -   9.677s ( 2.360s) group=1 best_score=0.556
5:   9.677s -  11.834s ( 2.156s) group=0 best_score=0.582
6:  11.834s -  14.171s ( 2.337s) group=1 best_score=0.595
```

観測されたグループは期待した `1, 3, 5` と `2, 4, 6` に一致しました。
各 embedding は 192 次元で、L2 norm は浮動小数点誤差の範囲で 1.0 でした。
生成された 6 ファイルはすべて 16 kHz mono PCM WAV でした。

同じ話者間の cosine similarity は 0.453 から 0.595、異なる話者間は
0.095 から 0.276 でした。3 番目の発話を group 0 に追加したスコアは 0.459
であり、しきい値 0.45 に対する余裕は 0.009 しかありませんでした。

`SCD elapsed` は SCD の推論と区間判定、`embedding elapsed` は 6 区間すべての
ECAPA-TDNN 推論と L2 正規化にかかった時間です。モデル初期化、入力音声の
デコード、WAV と JSON の生成は含みません。単発の参考値であり、厳密な
ベンチマークではありません。

## Verification environment

- machine: Mac Studio (Mac16,9)
- chip: Apple M4 Max
- memory: 128 GB
- OS: macOS 26.5.1 (25F80), arm64
- Python: 3.12.11
- NumPy: 2.5.1
- ONNX Runtime: 1.27.0
- execution provider: CPUExecutionProvider

## Interpretation and limitations

この入力では、ECAPA-TDNN embedding と単純な逐次しきい値方式により、既知の
2 話者を正しくグループ化できました。一方、最初の同一話者判定がしきい値に
近いため、しきい値 0.45 に十分な安全余裕があるとは結論できません。

この検証は単一の 2 話者音声に対する動作確認です。しきい値 0.45 が別の話者、
録音環境、発話時間、雑音、重複発話でも適切とは限りません。SCD の分割誤差は
embedding とグループ化の結果にも影響します。
