# Japanese live text and streaming PCM voice cloning with mlx-audio

**日本語を空白なしで追加しながら、Base モデルの ICL 声クローンを PCM で受け取れる lab 内の adapter を作った。**
全文入力・逐字入力・途中停止からの再開で生成符号と PCM が一致した。
ただし、ICL は参照音声の長さに応じて初期テキストを必要とする。入力を一文字受け取れば常に発声できるわけではない。

[上流 PyTorch の検証](../qwen3-tts-streaming-input/README.md)の続き。
[以前の MLX 声クローン比較](../../20/japanese-zero-shot-tts-compare/README.md)で確認した
causal prompt・罰則・復号器の参照 priming を、この lab に独立して実装した。
他 lab のコードは実行時に参照しない。mlx-audio 本体の checkout と kiapi は変更していない。

## 目的と判定方法

検証前に、次の順序を定めた。

1. 空白を挿入せず、確定済み token が全文 token 列の prefix と一致するか。
2. 同一入力の float32 fixture で、公式 PyTorch の causal ICL prompt、talker logits、greedy 符号と一致するか。
3. 同じモデル内で、全文・逐字・停止再開の入力スケジュールを変えても符号と PCM が変わらないか。
4. 通常の bf16 / sampling で終了まで生成できるか。初回 PCM、入力完了との前後、生成時間、再生待ちを測る。
5. ASR で読み落としを診断する。声の似方・自然さ・聴感の品質は人の試聴で判断する。

## 結果（2026-10-22）

Mac Studio / Apple M4 Max / 128 GB、macOS 27.0.1、Python 3.12.11。
mlx-audio **0.6.1**、MLX 0.32.4、transformers 5.20.2、非量子化 Base 1.7B bf16。
通常のデスクトップアプリは起動したまま。他のモデル推論は開始時に観測されず、ASR は別途実行した。
実運用負荷下の応答保証ではなく、小さい機能・性能の検証である。

### 日本語の確定と一致

- 日本語、引用符・改行・数字・英語混じり・絵文字・句読点なしを含む5文を、各20通りに分割。
  **100通りすべてで、確定済み prefix と close 後の全文 token 列が一致した。**
- bf16 の短参照は5条件×2回、長参照は3条件×1回、計13回が正常に EOS で終了した。
  同じ seed 0 の全文入力と逐字入力、全文入力と3秒停止で、**全コードブックの符号と float32 PCM が完全一致**。
  PCM の SHA-256 でも一致を確認した。短文と長文・参照2種類を合わせ、異なる波形は3種類。
- float32 の入力スケジュール比較も、先頭64フレームで符号・PCM が一致した。
  これは部分列の数値検証であり、greedy の自然な発話・EOS の検証ではない。
- push 後の close、close 後の書き込み拒否、cancel による待ちの解除、idle が EOS でなくエラーになることを確認した。

根拠: [source 検証](results/source/)、[bf16 schedule parity](results/bf16/schedule-parity.json)、
[PCM hash 監査](results/bf16/audit.json)、[長参照の監査](results/full-reference/audit.json)、
[float32 の先頭64フレーム](results/f32-schedule/schedule-parity.json)。

### 応答速度

短参照は **1.851秒**、参照 text 10 token / codec 24 frame。
最初に target **15 token** が確定すると prefill できる。その後の PCM 4 frame を出すには追加の text row も要る。
参照の符号と声の埋め込みは測定前に準備して各発話で再利用する。

全文入力 control もこの adapter の causal path を使い、stock `Model.generate()` の既定 layout との波形一致は検証していない。

短参照・2回目の値。時間は producer / generation を開始してから。全条件は [表](results/bf16/table.md) と各 JSON にある。

| 入力 | 初回 PCM | 入力終了 | 生成時間 / 音声長 | RTF | 即再生の予測途切れ |
|---|---:|---:|---:|---:|---:|
| 短文を全文投入 | 0.138秒 | 0.000秒 | 1.95 / 6.80秒 | 0.286 | 0 |
| 短文を40ms間隔で1文字ずつ | 2.180秒 | 1.980秒 | 3.98 / 6.80秒 | 0.585 | 0 |
| 長文を全文投入 | 0.136秒 | 0.000秒 | 5.44 / 19.36秒 | 0.281 | 0 |
| 長文を40ms間隔で1文字ずつ | **2.173秒** | **5.711秒** | 9.86 / 19.36秒 | 0.509 | **0** |
| 先頭の短文を投入し、初回PCMから3秒後に続きを追加 | **0.138秒** | 3.141秒 | 8.38 / 19.36秒 | 0.433 | 2.481秒 |

- 先頭の45文字の文がまとまって届けば約0.14秒で PCM が返る。LLM がその文を作る時間は含まない。
- 文字を順に送ると、境界確定・ICL prefix を待つ。**短文の逐字入力は入力終了前に出なかった**。
  長文では終了前から音声が返り、その後も同じ KV cache と decoder を保って続きを扱えた。
- 1 chunk は4 codec frame、通常 **0.32秒分**の 24kHz mono PCM。
- 全文を渡せる warm control の計算は実時間の約 **3.5倍**。逐字入力・停止の RTF には入力待ちが含まれる。
  別モデル・別参照・別精度だった前 lab の PyTorch 数値との制御された速度比較ではない。
- 3秒入力停止でも波形は変わらないが、再生バッファが尽きれば音は途切れる。
  このケースの2.48秒はその待ちであり、入力なしに音声を作り続けられるという意味ではない。
- モデル取得・Python import・モデル load・参照の準備はタイマー外。計測前に OS/Metal cache が温まっていた。
  この main process の load 0.250秒、参照準備0.025秒を cold start の保証には使わない。

参照を **6.588秒**にすると、参照 text 32 token / codec 83 frame、必要 target prefix は **52 token**。
長文の逐字入力は **4.691秒**で初回 PCM（入力終了5.676秒）、同じ長文を先に渡せれば0.220秒だった。
計算の RTF は0.286。生成音声は18.72秒で、短参照とは別の波形になる。
[長参照の全結果](results/full-reference/table.md)。

したがって「0.14秒で声クローン会話が応答する」と一括りにはできない。
先頭テキストがどれだけ届いているか、参照の長さ、実際の入力間隔が初回遅延を決める。
参照を短くしたときの声の似方・自然さはまだ本人に聞いてもらっていない。

### 読みの診断

[短参照の ASR](results/bf16/transcripts.json)・[長参照の ASR](results/full-reference/transcripts.json) は
固定版 Whisper large-v3-turbo、temperature 0。
今回の短文・長文では、「少し」「駅前」を含め、句読点・空白を除いた原稿と一致した。
NFKC・小文字化・句読点/空白除去後の [CER](results/bf16/asr-scores.json) は0。
同じ PCM は1回だけ ASR を実行して結果を再利用した（13出力、3種類の異なる波形）。

これは日本語全般の品質や声の類似度の評価ではない。
以前の「空白を挿入する」経路で生じた、この原稿の ASR 変化を再現しないことと、
入力スケジュールだけでは元の全文生成の声・読み・抑揚を変えないことを確認した。

### PyTorch との float32 gate

PyTorch qwen-tts 0.1.1 / torch 2.14.1 / transformers 4.57.3、CPU float32 / SDPA。
公式の `generate_voice_clone(non_streaming_mode=False)` が talker に渡す prompt を capture した。
自作の prompt builder を参照側の正解として使っていない。

同じ参照 codec と prefix を両 backend に与えた [fixture 結果](results/parity/float32-parity.json):

| 対象 | 結果 |
|---|---|
| causal ICL prompt | max abs 1.67e-6、cos 約1.0 |
| trailing text | max abs 0 |
| 同一 prompt を与えた talker logits | max abs 3.81e-5、KL 1.73e-10、先頭 argmax 一致 |
| 最初の15フレーム×16コードブック | **全240個の符号が一致** |

独立に参照音声を encode した符号は **98.64%一致**で、完全一致ではない。
その符号を使った end-to-end prompt の cos は0.998462。
上の gate は layout と同じ入力のモデル計算を検証しており、両 backend の独立した音声 encode から
最後まで同じ波形になると主張するものではない。

## 実装

- `live.py`: `TextSource.push(str)` / `close()` / `cancel()` と `generate_live(model, prompt, source)`。
  producer は Unicode を condition へ追加するだけで、モデル操作は consumer だけが行う。
- `TextSource.poll()` は累積 text を tokenizer の pre-tokenizer に渡し、伸びる可能性のある末尾 pre-token を保留する。
  確定部分をまとめて token 化し、以前の token 列が変わっていないことも検査する。
  **空白の挿入・除去、単語ごとの独立 token 化をしない。** 最後の部分は明示 close で確定する。
  句読点などの境界まで来ない長い文字列では待つ。最適な最小遅延の日本語 tokenizer を保証していない。
- `prepare_clone()` は参照の codec と話者 embedding、language/role prefix を準備。
  `generate_live()` は参照 text + 確定 target text を参照 codec に重ねる。
  初期 target prefix が不足したら待つ。未来の text を予測した pad で reference prefill を埋めない。
- prefill 後は1つの talker KV cache と code predictor cache を使い、text row を1つずつ追加。
  text に追いついたら forward を止めて待つ。明示 close 以後だけ text EOS / pad を使う。
- checkpoint と同じ sampling（temperature .9 / top_k 50 / top_p 1、罰則1.05を全生成履歴へ）を使用。
  decoder を参照 codec で prime してから新しい符号だけを streaming decode する。
- source の idle は既定30秒でエラーにする。勝手に発話終了と推測しない。
  text 上限65,536文字、codec上限1,000 frame（EOSに至らなければエラー）。
- **1モデルにつき同時に1発話**。decoder の可変状態を使う。サービス向けの同時実行・transport の実装ではない。
  private API に依存する adapter なので mlx-audio の版を固定している。

## 失敗・未完了の試行

- 最初は6.588秒の参照と短めの長文を使い、必要な52 tokenに満たない先頭 text から最初の PCM を待っていた。
  producer が30秒で期限切れになった。これは入力予算の不足で、追加 text を待つ consumer と相互待ちになっていた。
  [pilot](results/pilot-full-reference/) に残し、以後は gate の前に必要 prefix + 8 token 以上を渡す。
  この失敗の集計処理も存在しない WAV を開いて落ちたため、失敗した run を集計対象から除くよう修正した。
- 1.851秒の参照で float32 / greedy を終了まで生成すると、短文・その逐字入力・長文の3 run が
  1,000 frame / 80秒で上限に達した。[結果](results/greedy-failure/)を保持。
  次の in-progress run は情報が増えないため止め、以後 greedy は数値比較の prefix に限った。
  全文と逐次で同じ退化が起きたので、greedy の一致を自然な TTS の合格条件としない。
  full-reference float32 の先頭64 frame もほぼ無音（peak 約0.000898）で、試聴の代表には使わない。
- 参照 fixture exporter の初稿は fork 専用 helper を公式版にも仮定して失敗した。
  公式公開生成入口の capture に直した。その後、2次元の token tensor の軸を間違えて空の token 列を保存したが、
  dtype error で検出し、修正後に fixture と gate を再生成した。失敗した fixture の数値は gate に使用していない。
- 5条件×1回の bf16 pilot でも正常生成とスケジュール一致を確認した。
  main の2回測定と同じ seed で同じ波形のため、main と合わせて独立した品質標本として数えない。

未検証: 多数の文と参照話者、長時間/実際のLLMの到着間隔、割り込み音声の実機再生、
並列セッション、30秒以上の停止を含むサービス運用、話者の類似度・自然さの人の評価。
kiapi への導入や upstream PR は今回行っていない。

## 再現

Apple Silicon Mac、uv、mise が必要。大きい checkpoint・生成 WAV・数値 fixture は git に含めない。
モデルとソースの pin、依存全解決版は constants と2つの lockfile、入力音声の SHA-256 と切り出し位置は
`results/*/reference.json` にある。入力アセットの SHA-256 が違えば実行を止める。

```sh
# リポジトリの root から（共有アセットを先に取得する）
mise -C 2026/10/22/qwen3-tts-mlx-live-clone run parity
mise -C 2026/10/22/qwen3-tts-mlx-live-clone run default --output output-bf16
```

lab のディレクトリから、各測定を個別に実行する場合:

```sh
uv run --frozen tokenizer_check.py
uv run --frozen bench.py --output output-bf16
uv run --frozen bench.py --reference full --cases long_full long_chars long_pause --trials 1 --output output-full-reference
uv run --frozen bench.py --dtype float32 --reference full --temperature 0 --prefix-frames 64 --cases long_full long_chars long_pause --trials 1 --output output-f32-schedule
# モデル生成が終わってから。生成と ASR を同じ GPU で並行させない。
uv run --frozen transcribe.py output-bf16 output-full-reference
uv run --frozen audit.py output-bf16 output-full-reference
uv run --frozen summarize.py output-bf16 --destination results/bf16
uv run --frozen summarize.py output-full-reference --destination results/full-reference
uv run --frozen replay.py output-bf16 long_chars-1
```

WAV は `output-bf16/` 等に残る。通常の WAV は到着待ちを除いて PCM を連結したもの。
`*-arrival-replay.wav` は到着時刻どおりに startup / underrun の無音を挿入した再生シミュレーションで、
実際のスピーカーから録った音ではない。実機の音声デバイス遅延は測定していない。

### 固定対象と provenance

- [mlx-audio 0.6.1](https://pypi.org/project/mlx-audio/0.6.1/)（MIT）
- [MLX Base bf16](https://huggingface.co/mlx-community/Qwen3-TTS-12Hz-1.7B-Base-bf16)、revision `a6eb4f68e4b056f1215157bb696209bc82a6db48`
- [公式 Base](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-Base)、revision `fd4b254389122332181a7c3db7f27e918eec64e3`、PyPI qwen-tts 0.1.1
- Qwen checkpoint / 参照アルゴリズムは Apache-2.0。声の参照は `kiarina/test-assets` の既存共有会話音声。
- ASR: `mlx-community/whisper-large-v3-turbo`、revision `a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb`、mlx-whisper 0.4.3。
