# Apple Speaker Lab — 実マイクの区間ASRを体験する

## 目的と操作

Macで `record → Silero VAD → pyannote SCD → ECAPA話者ID → SpeechAnalyzer` を試す小さなFlutterアプリ。
prototype・ChatGPT・WebRTCは使わず、音声は端末内で処理する。

```sh
mise -C 2026/10/19/apple-speech-scd-asr run demo
```

1. 「準備完了」になったら、必要なら入力マイクを選ぶ。
2. 「実マイクを開始」を押し、初回のマイク使用許可に対応する。
3. 自然に話し、交代時には少し間を入れる。2人なら最初の方→別の方→最初の方を試す。
4. 「停止して確定」で残りの音声を解析する。完了後に再開すると、文字・時刻・話者の登録をリセットする。

起動だけではマイクを取得しない。文字は確定した区間から順に表示する。話している途中の逐語字幕ではない。
アプリを閉じるとプロセスとマイク取得は終了する。体験用に待機画面を開いたままにする場合も、開始前は録音していない。

## 表示の見方

- `speaker-N`: ECAPAの類似度で割り当てた候補。同じ人が別IDになることもあり、人物の正解ではない。
- 「話者未確定」: 短い／曖昧な声を既存話者へ無理に割り当てない。後から登録ができるとIDが更新される場合がある。
- 音声の開始・終了: 最初のPCMからのサンプル時計。SCD推定値で、単語時刻の正解ではない。
- `ASR …ms`: 区間PCMをnativeへ渡して最終結果を受け取るまで。MethodChannelも含む。
- `音声区間末尾→表示 …ms`: VADによる区切り待ち、解析キュー、SCD、埋め込み、ASRを含む。
  ASRだけが速くても、この値が大きければ体感は遅い。

既定は「話者変化で早期確定（逐次SCD）」がON。250msごとのSCDで安定した変化位置を確認し、左区間を先に認識する。
無音500ms・停止は末尾の区切り、話者変化がない連続発話の最大15秒は安全な上限として使う。
OFFにすると無音500ms・最大6秒でVADの音声塊が終わってからSCDを呼ぶ比較用の初版になる。
両方とも確定区間のASRで、逐語字幕ではない。比較・既知の失敗は [STREAMING.md](STREAMING.md)。

話者登録は先行labの改良ルール（照合0.45、新規2秒、近傍0.35〜0.45は3秒、短い一致で登録を汚染しない）を本labへコピー。
未知話者を確定と偽らず、文字は話者未確定でも表示する。
0.5秒未満はASRを省略する。旧方式はSCDで重なり／非話者とされた区間も省略する。逐次方式はVAD範囲の確定音声を渡すため、区間内の重なりの分離までは行わない。
時間上限での分割や誤ったSCD境界は単語の途中に入り得る。

## 実装・依存

- `app/lib/main.dart`: record、VAD/SCDの直列キュー、話者、UI、区間ID照合、計測。
- `app/lib/local/`、`speaker_tracker.dart`: 先行audio labのDart実装を本labへコピー。以後は本labが所有し、sibling importしない。
- `app/macos/Runner/MainFlutterWindow.swift`: `apple_asr` MethodChannelでPCM16/mono/16kHzを直接受ける。
  WAVや会話文をディスクに書かず、区間ごとにAnalyzerを作り、入力終端・finalize・results終了後に同じ要求IDで返す。
- Flutter 3.47.2 / Dart 3.13.2、record 7.1.2、flutter_onnxruntime 1.9.0。
  既存labと解析条件を合わせるため同じpackage pinを維持し、実解決はpubspec.lockで固定する。
- 新規Mac scaffoldはSwiftPM。ONNX native SDKはPackage.resolvedの1.28.0で、以前のCocoaPods構成と同一binaryではない。
  既存labとのモデル数値一致を今回再保証してはいない。重みは `fixtures/live-models.json` のSHA-256で検査する。
- macOS 26以上、Apple SpeechTranscriberの日本語モデルが利用可能なMacが必要。
  モデルが未取得なら最初の準備でOSのassetを取得する。モデルダウンロードと音声送信は別で、音声を外へ送るコードはない。

VAD待ち最大128フレーム、解析待ち最大12音声塊、表示200行、話者16候補、観測256件・各話者の登録32件まで。
上限超過は黙って捨てず停止する。音声と文字・埋め込みはRAM内のみ。通常モードは標準出力へ会話文を出さない。
停止ではcaptureを閉じ、VAD残りをflushし、解析・ASRを回収する。停止回収中の再開は無効。
ASR要求は20秒のタイムアウト。マイク切替は停止中だけ可能で、長時間・デバイス抜き差し・強制中断の耐性は未検証。

## 試験

```sh
# 実マイクを開かず、共有素材を実時間相当で投入し、数値だけをstdoutへ出して終了
APPLE_SPEAKER_AUTOTEST=1 mise -C 2026/10/19/apple-speech-scd-asr run demo
```

共有素材試験は、保存済みのSCD境界を渡す前のベンチマークと違い、VAD/SCD/埋め込みもアプリ内で実行する。
実マイクの聴感や人物の正解を代用するものではない。

### 初版の保存した共有素材の結果

releaseアプリでVAD/SCD/ECAPAとnative ASRを通し、7区間すべてで文字を取得し、要求IDの不一致・処理エラー0。
候補は2話者、短い2区間は話者未確定のまま保持した。SCDの正解や全文字の話者の正確さを証明する値ではない。
ASR中央値98ms・最大271ms、音声区間末尾→表示は約198〜5305ms。
無音のない会話ではVADの最大6秒を待ってからSCDを実行するため、末尾→表示には数秒かかる区間がある。

初回の共有素材再生は20ms sleepを積み重ねたため実時間の遅れが蓄積した。
`results/app-fixture-initial.json` を保存し、再生を音声サンプル時計の予定時刻に合わせた後の
`results/app-fixture.json` を現在の結果とする。実マイクのhardware sample clockにはこの人工sleepを使わない。

`results/app-validation.json` は失敗・未確定を含めた整合性の検算であり、実マイクや人物識別の合格ではない。
現在の逐次方式の比較は [STREAMING.md](STREAMING.md)。本人から逐次SCD版の性能は問題ないという体験評価を得た（詳細は同文書）。話者IDの正確さ・長時間は別の未確認事項。音声も文字も検証ファイルへ保存しない。
