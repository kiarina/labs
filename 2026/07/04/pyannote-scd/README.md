# Pyannote SCD speaker segmentation

Pyannote Segmentation 3.0 の ONNX モデルを使い、会話音声をモデル内の
話者インデックスごとの区間へ分割する検証です。

## Purpose

2 話者の短い会話に対して、Pyannote の segmentation モデル単体と単純な
後処理で話者交代位置を検出できるかを確認します。

明らかにしたい問いは次のとおりです。

- 14 秒の会話を、時間的に連続した話者区間へ分割できるか
- Apple Silicon 上の CPUExecutionProvider で実時間より高速に処理できるか

評価では、生成された WAV を聴いて話者交代位置を確認し、推論時間を入力音声長で
割った real-time factor (RTF) を記録します。

## Input

共有 test asset の次の音声を使用します。

```text
assets/mp3/conversation_2speaker_14s_16k.mp3
```

音声のシナリオは、2 人が交互に発話する次の会話です。

```text
Speaker 1: もしもし、もう駅に着いた？
Speaker 2: うん。今、改札出たところ。そっちは？
Speaker 1: こっちはまだ電車。あと5分くらいかな。
Speaker 2: 了解。じゃあ、カフェの前で待ってるね。
Speaker 1: 助かる。今日は結構寒いね。
Speaker 2: ほんと、マフラー持ってきて正解だった。
```

## Requirements

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- [FFmpeg](https://ffmpeg.org/)
- `curl`

## Run

リポジトリルートから実行します。

```sh
mise -C 2026/07/04/pyannote-scd run
```

初回実行時には、Hugging Face の
`onnx-community/pyannote-segmentation-3.0` から通常精度の
`onnx/model.onnx` を lab 内へダウンロードします。ONNX モデルと出力 WAV は
Git の管理対象外です。

既存の `output/` は実行ごとに削除し、検出区間を 16 kHz mono PCM WAV として
生成し直します。

```text
output/
├── speaker_0_001.wav
├── speaker_1_002.wav
└── ...
```

入力、モデル、出力先は変更できます。

```sh
uv run python main.py \
  --audio path/to/audio.mp3 \
  --model path/to/model.onnx \
  --output path/to/output
```

## Detection settings

- input sample rate: 16 kHz mono
- inference window: 10 seconds
- model speakers: 3
- maximum simultaneous speakers: 2
- active speaker threshold: 0.5
- overlap margin: 0.1
- minimum speaker change: 100 ms
- minimum speech segment: 100 ms
- execution provider: CPUExecutionProvider

モデルの 7 クラス powerset log probabilities を 3 話者の確率へ変換します。
無音フレームは前後の話者へ割り当て、短い話者状態を隣接区間へ統合します。

## Observed results

Mac Studio (Apple M4 Max) でウォームアップなしの 1 回の実行結果は次のとおり
でした。

```text
audio duration: 14.171s
SCD elapsed: 0.019s
SCD real-time factor: 0.001x
frame duration: 16.978ms
segments: 6
001:   0.000s -   1.851s ( 1.851s) speaker_2
002:   1.851s -   4.737s ( 2.886s) speaker_1
003:   4.737s -   7.317s ( 2.581s) speaker_2
004:   7.317s -   9.677s ( 2.360s) speaker_1
005:   9.677s -  11.834s ( 2.156s) speaker_2
006:  11.834s -  14.171s ( 2.337s) speaker_1
```

観測された 6 区間は隙間や重複なく入力の 14.171 秒全体を覆い、話者
インデックスは各境界で交互に切り替わりました。生成物について、6 ファイルの
合計が 226,736 samples（14.171 秒）であり、すべて 16 kHz mono PCM である
ことを確認しました。

生成した 6 個の WAV を聴取した結果、各ファイルはシナリオの 1 発話ずつに
正確に分離されていました。モデル内の話者インデックスとシナリオ上の話者は
次のように対応し、全区間で一貫していました。

| Model output | Scenario speaker | Utterances |
|---|---|---:|
| `speaker_2` | Speaker 1 | 3 |
| `speaker_1` | Speaker 2 | 3 |

`SCD elapsed` は ONNX 推論と話者区間判定にかかった時間です。モデルの初期化、
FFmpeg による入力デコード、WAV の生成は含みません。単発の参考値であり、厳密な
ベンチマークではありません。

## Verification environment

- machine: Mac Studio
- chip: Apple M4 Max
- memory: 128 GB
- OS: macOS 26.5.1 (25F80), arm64
- Python: 3.12.11
- ONNX Runtime: 1.27.0
- execution provider: CPUExecutionProvider

## Interpretation and limitations

出力の `speaker_0` などはモデルの 10 秒窓内の話者インデックスです。
話者埋め込みによる照合や clustering は行っていないため、窓をまたいで同じ
インデックスが同一人物を表す保証はありません。

この検証では上記シナリオとの照合と生成 WAV の聴取により、6 発話すべての
分離が正確であることを確認しました。ただし、単一の 2 話者音声に対する
動作確認であり、複数音声や重複発話を含むデータセットによる定量評価は
行っていません。`overlap` は上位 2 話者の確率差が小さいフレームを表しますが、
実際の重複発話であることを保証しません。
