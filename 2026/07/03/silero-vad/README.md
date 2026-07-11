# Silero VAD speech segment extraction

Silero VAD の ONNX モデルを使って、会話音声から発話区間を検出する検証です。
検出した区間は、確認しやすいように 16 kHz mono WAV として個別に
`output/` へ切り出します。

## Input

共有 test asset の次の音声を使用します。

```text
tests/assets/mp3/conversation_2speaker_14s_16k.mp3
```

## Requirements

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- [FFmpeg](https://ffmpeg.org/)
- `curl`

## Run

リポジトリルートから実行します。

```sh
mise -C 2026/07/03/silero-vad run
```

初回実行時には、Silero VAD の公式リポジトリから `silero_vad.onnx` を
lab 内へダウンロードします。モデルと出力 WAV は Git の管理対象外です。

実行すると、検出した発話区間と出力先が表示されます。

```text
audio: .../tests/assets/mp3/conversation_2speaker_14s_16k.mp3
audio duration: 14.171s
VAD elapsed: 0.028s
VAD real-time factor: 0.002x
speech segments: 12
001:   0.162s -   1.726s ( 1.564s) -> .../output/speech_001.wav
002:   2.050s -   2.462s ( 0.412s) -> .../output/speech_002.wav
...
```

`VAD elapsed` は Silero VAD の推論と発話区間判定にかかった時間です。
モデルの初期化、FFmpeg による入力音声のデコード、検出区間の WAV
切り出しは含みません。`VAD real-time factor` は処理時間を入力音声の長さで
割った値で、値が小さいほど実時間に対して高速に処理できています。
実測値は実行環境によって変わります。

再実行時は既存の `output/` を削除してから、次の形式で生成し直します。

```text
output/
├── speech_001.wav
├── speech_002.wav
└── ...
```

## Detection settings

- sample rate: 16 kHz
- chunk size: 512 samples (32 ms)
- speech threshold: 0.5
- negative threshold: 0.35
- minimum silence: 100 ms
- minimum speech: 250 ms
- speech padding: 30 ms

ONNX Runtime の state と直前 64 samples の context をチャンク間で引き継ぎます。
これは参照実装と Silero VAD のストリーミング処理に合わせたものです。

## Verification environment

次の環境で実行しました。

- machine: Mac Studio (Mac16,9)
- chip: Apple M4 Max, 16 cores (12 performance + 4 efficiency)
- memory: 128 GB
- OS: macOS 26.5.1 (25F80), arm64
- Python: 3.12.11
- ONNX Runtime: 1.27.0
- execution provider: CPUExecutionProvider

上記の出力例はウォームアップなしの 1 回の実行結果です。14.171 秒の入力に
対して VAD 処理は 0.028 秒、real-time factor は 0.002x でした。
厳密なベンチマークではなく、この検証を実行した時点の参考値として記録します。
