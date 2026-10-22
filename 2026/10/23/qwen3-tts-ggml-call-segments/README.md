# Call speech in short spans on qwentts.cpp (Qwen3-TTS 1.7B BF16)

Spirits Garden の試作の通話は、gpt-live の文字起こしが少しずつ届くのを短い区間に区切り、区間ごとに参照の声で生成して 1 つの発話としてつなぎ、
最初の音から 1 秒待って鳴らします（今は kiapi の MLX で、参照を準備した状態を区間ごとに複製する独自の生成）。
TTS エンジンを [qwentts.cpp](https://github.com/ServeurpersoCom/qwentts.cpp) にすると、その口は「全文を渡して流しで受け取る」だけで、文を少しずつ足しながら生成する口がありません。
この lab は、**区間ごとに 1 要求を出すだけで、今の通話と同じ体験（最初の音・途切れ・割り込み）になるか**を、同じ入力で確かめます。

前の lab: [Qwen3-TTS live audio decoupling](../../22/qwen3-tts-live-audio-decoupling/README.md)（今の方式を決めた lab。入力・到着の予定・区切りの規則・seed をここから写した）、
[Qwen3-TTS on ggml](../qwen3-tts-ggml-compare/README.md)（qwentts.cpp を選んだ lab）。

## Purpose

- 区間ごとに 1 要求で、最初の音・途切れ（1 秒待ちあり / なし）は、今の方式（前の lab の `segments_cached`）と比べてどうか
- 区間の要求を順に出すのと、次の区間を先に出す（2 本同時）のとで違いがあるか
- 割り込み（途中で止めて次の返事）にどれだけかかるか
- 区間のつなぎ目の抑揚（人が聞いて判断する）

## Summary

2026-10-23。Mac は MacBook Pro（Apple M1 Max、Metal）、Windows は RTX 3080 Ti（CUDA）。qwentts.cpp の `tts-server`、1.7B Base BF16、ICL。日本語・英語 × 3 seed。

- **区間ごとに 1 要求で、今の方式と同じ体験になる**。普通の届き方と実際の通話の届き方では、**1 秒待てば Mac も Windows も 3 seed 全部で途切れ 0**（今の方式の結論と同じ）。待ちなしでも途切れは最大 0.06〜0.73 秒
- 最初の音（最初の文字が届いてから）は、日本語の普通の届き方で Mac 1.86 秒・Windows 1.72 秒（今の方式は 1.96 秒）。ほとんどは最初の区間の文字が届くまでの時間で、生成は区間の要求から 0.1 秒（Mac）・0.03 秒（Windows）で音が出る
- 文字の届けが 2 秒止まる悪い場合は、1 秒待っても途切れが残る（Mac 日本語 1.23 秒）。今の方式も同じ（0.79 秒）で、どの方式でも文字が来なければ声は出ない
- **次の区間を先に出しても良くならない**（Mac では少し悪い）。順に出せば足りる
- **割り込み**: 途中で接続を切ってから次の返事の最初の音まで、Mac 0.66〜0.80 秒・Windows 0.25〜0.26 秒（普段の最初の音は 0.1 秒・0.03 秒）。サーバーは接続が切れたのを次の書き込みの失敗で知るので、数フレーム余分に作る。アプリに組み込んで C の ABI の取り消し（1 フレームごとに確かめる）を使えば縮む見込み（未確認）
- 読みの破綻は無い（Whisper の文字誤り率、日本語 0、英語 0〜0.023）。区間のつなぎ目の抑揚は聞いて判断する

## Run

macOS（Apple Silicon）、uv、mise、CMake、Xcode のコマンドラインツールが要ります。

```sh
mise -C 2026/10/23/qwen3-tts-ggml-call-segments run
```

`.mise/tasks/default` は qwentts.cpp を固定の commit で取って Metal で build し（`vendor/`）、重みを取り（`download.py`）、`call.py` と `interrupt.py` を走らせ、`evaluate.py` で文字起こしと要約・ページを作ります。
聞くのは `mise run listen`（`http://127.0.0.1:8779/`）。

Windows（CUDA）は [qwen3-tts-ggml-compare](../qwen3-tts-ggml-compare/README.md) と同じ build（`windows/build-qwentts-cuda.cmd`）で、`output/reference-speaker1.wav` を置いてから
`windows\run.cmd call.py`・`windows\run.cmd interrupt.py`。結果（`output/call-windows.json`・`interrupt-windows.json`・`output/windows-*/`）を Mac の `output/` に写して `evaluate.py`。

別の参照の声: `REFERENCE_LABEL`・`REFERENCE_AUDIO`・`REFERENCE_TEXT_FILE`（`engines/common.py`）。参照の音声は lab に含めません。

## What is compared

`call.py` が、前の lab と同じ入力で通話を再現します。

- 文: 日本語「うん、今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？」、英語「Tokyo is a busy city with quiet gardens and many small cafes. We can take a short walk and have some tea later.」
- 届き方: `ordinary`（日本語 130 ms・英語 60 ms に 1 文字）、`recorded`（実際の通話の累積の文字数の割合を文に当てはめたもの。`schedules.json`、前の lab から写した）、
  `pause`（`ordinary` の 3 分の 2 で 2 秒止まる）、`full`（全文を一度に。比べ用）
- 区切りの規則: 試作と同じ（日本語は 8 文字以上で句読点、無ければ 24 文字。英語は 14 文字以上で句読点、無ければ 6 語）。届いた文字が規則を満たすたびに区間を確定する
- 生成: 区間ごとに `POST /v1/audio/speech`（`response_format: "pcm"`、同じ seed）。`serial` は前の区間が終わってから次を出す。`pipelined` は区間が確定したらすぐ出し（最大 2 本、`--max-batch 2`）、再生の順番は守る（前の区間が届き終わるまで次の区間の音は鳴らせない）
- 測るもの: 最初の文字から、再生の順番での最初の音。最初の音から 0・0.5・1 秒待って鳴らし始めたときの、音が足りない時間の合計（20 ms 未満は数えない。前の lab と同じ）
- seed 42・43・44、`full` は 42 だけ

`interrupt.py`: 長い文を頼み、1.2 秒ぶんの音が届いたところで接続を切り、すぐ次の返事（「はい、どうしましたか？」）を頼む。切ってから次の最初の音までを 5 回。

条件をそろえられなかったところ:

- 今の方式（MLX、`segments_cached`）の数字は前の lab のもので、この lab では走らせていない。機械（MacBook Pro M1 Max）と入力は同じ
- 今の方式は参照の準備状態を区間ごとに複製する。qwentts.cpp は区間ごとにプロンプト（参照の文字起こし＋参照の符号＋区間の文）を prefill し直す（prefill は Mac で約 50 ms）
- 乱数の作りが違うので、同じ seed でも前の lab と同じ音ではない

## Conditions

- qwentts.cpp `5916bf7c79dbb4e66fc059cdc507a79a23a28bb4`、重み `Serveurperso/Qwen3-TTS-GGUF`（`b7ee2e8`）の `qwen-talker-1.7b-base-BF16.gguf` と `qwen-tokenizer-12hz-F32.gguf`。サンプリングはエンジンの既定（`generation_config.json` と同じ）
- Mac: MacBook Pro、Apple M1 Max、64 GB、macOS 27.0.1、Metal。Windows: Core i9-12900K、RTX 3080 Ti 12 GB、Windows 11、CUDA Toolkit 13.4、ドライバ 610.88
- 参照の声: 共有の素材 `tests/assets/mp3/conversation_2speaker_14s_16k.mp3` の話者 1（6.6 秒）と、その文字起こし
- Whisper large-v3-turbo（mlx-whisper 0.4.3）

## Observed results (2026-10-23)

`output/summary.md` から（3 seed の中央値・最大。CER は 3 seed の平均）。

| 機械 | 言語 | 届き方 | 最初の音 | 途切れ・待ちなし（中央 / 最大） | 途切れ・1 秒待ち（最大） |
|---|---|---|---:|---:|---:|
| Mac | ja | ordinary | 1.86 秒 | 0.00 / 0.22 秒 | **0** |
| Mac | ja | recorded | 1.39 秒 | 0.00 / 0.06 秒 | **0** |
| Mac | ja | pause | 1.86 秒 | 1.99 / 2.23 秒 | 1.23 秒 |
| Mac | en | ordinary | 1.73 秒 | 0.31 / 0.46 秒 | **0** |
| Mac | en | recorded | 1.30 秒 | 0.59 / 0.72 秒 | **0** |
| Mac | en | pause | 1.73 秒 | 1.48 / 1.91 秒 | 0.94 秒 |
| Windows | ja | ordinary | 1.72 秒 | 0.00 / 0.17 秒 | **0** |
| Windows | ja | recorded | 1.30 秒 | 0.00 / 0.10 秒 | **0** |
| Windows | ja | pause | 1.77 秒 | 1.81 / 2.20 秒 | 1.20 秒 |
| Windows | en | ordinary | 1.54 秒 | 0.11 / 0.22 秒 | **0** |
| Windows | en | recorded | 1.20 秒 | 0.53 / 0.61 秒 | **0** |
| Windows | en | pause | 1.58 秒 | 0.79 / 0.94 秒 | **0** |

（`serial`。`pipelined` は `output/summary.md`。どの組でも `serial` と同じか少し悪い。）

前の lab の今の方式（`segments_cached`、Mac、3 seed の中央値）: 最初の音 日本語 1.963 秒・英語 1.828 秒、待ちなしの途切れ 日本語 0・英語 0.618 秒、1 秒待てば 0。2 秒止まる場合は 1 秒待っても 日本語 0.791 秒・英語 1.249 秒。

- `full`（全文を一度に）は最初の音 Mac 0.09 秒・Windows 0.03〜0.04 秒、途切れ 0
- 英語の `recorded` の待ちなしの途切れ（0.5〜0.7 秒）は、区間の確定の後に次の文字の到着が遅いところで出る。1 秒待てば消える
- 割り込み（`output/interrupt-*.json`）: 切ってから次の最初の音まで Mac 0.662・0.715・0.689・0.804・0.683 秒、Windows 0.261・0.255・0.252・0.253・0.262 秒。サーバーのログには毎回 `on_chunk callback aborted the synthesis`

### Listening

（オーナーが聞いた結果をここに書く。未）。2026-10-23 に、フリー素材のキャラクターの声（悲しみの読み）を参照にした同じ形の音も Mac で作った（`output/kanashimi.html`、lab の外の音声）。

## Limitations

- 文は日本語と英語の 1 つずつ、seed 3 つ。長い返事、複数の返事が続く通話、本物の gpt-live との接続は試していない
- 区間ごとに独立に作るので、区間をまたいだ抑揚のつながりは今の方式と同じく持たない（どちらも前の区間の生成を次に渡さない）。聞いて確かめる
- 割り込みは HTTP の接続を切る形だけ。アプリに組み込んだ形（C の ABI の取り消し）は試していない
- 今の方式の数字は前の lab のもので、同時に走らせて比べたものではない
