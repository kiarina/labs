# VAD・話者分割後の音声だけを ChatGPT 認証 ASR へ送る

## 問いと評価方法

record の取得と ASR を分離し、ローカルの Silero VAD → pyannote-segmentation-3.0 → ECAPA-TDNN で認識対象区間と継続的な話者IDを決める。その区間の音声だけを ChatGPT 認証 WebRTC に送り、文字起こしと区間ID／話者IDを対応付ける。prototype は対象外。

評価する項目は、(1) 無音などが除外される、(2) 同じ話者の再登場を追える、(3) 文字起こしの遅延で話者IDが混ざらない、(4) 無発声を実際の非ゼロ受信 PCM で判定する、(5) 途中結果とサーバーの確定通知を区別できる、の5点。

まず共有の2話者会話（14.171秒）に前2秒・後3秒の無音を加え、32msずつ実時間で入力する。合成／再生入力と実マイクの record 経路は別に扱う。実マイクは本人がボタンを押した30秒間だけ取得する。

## 今回試す方式

- 音声取得：record 7.1.2、PCM16 / 16 kHz / mono。VAD は512 samples単位。
- VAD：Silero、閾値0.5、無音500ms、pad300ms、発話上限15秒。
- 話者分割：pyannote、閾値0.5、overlap margin0.1、最小変化・発話100ms。
- 認識対象：話者区間のみ、0.5秒以上。重なり・無音・短い区間は送らず、理由を残す。
- 話者ID：ECAPAのコサイン類似度0.45。1.5秒未満の発話では新しい話者を作らない。まだ話者が存在しなければ未確定にする。埋め込みはプロセス内だけに保持。
- 認識待ちキュー：VAD音声12件を上限にし、超過は明示的なエラーとする。ASRは直列。

**一つの認識対象区間ごとに WebRTC / voice session を新規作成する。** 接続にローカルの segment_id を固定し、音声モデルへ話者IDや期待文は渡さない。別区間の文字起こしが遅れても別の接続へ届くので混同しない。一つの接続に話者を順次切り替えて送り、到着時刻だけでIDを付ける方式は実装しない。

返却された差分が1.8秒止まり、送信終了から2.5秒経過したら暫定結果を取り出す。最大待機は送信終了後12秒。サーバーの user transcript done がなければ `quiescent_provisional` と記録する。無通信時間の経過を認識完了保証にはしない。接続を閉じることで区間の所有を確定するが、未到着の文字を失う可能性は残る。

音声は48kHzへ変換して、同じ lab の外部入力ブリッジから通常の WebRTC audio track として送る。無音 callback／codec packet 自体は流れるが、前後の待機中に元マイクの非対象音声を送ることはしない。返答禁止 prompt は使用するが専用 transcription モードではない。出力はローカルで消音し、その前の PCM を測る。消音を無発声成功の根拠にしない。

## 実行

macOS 14以上、Flutter 3.47.2 / Dart 3.13.2、flutter_onnxruntime 1.9.0、flutter_webrtc 1.6.2+hotfix.4、Codex CLI 0.163.0。依存解決は `asr/app/pubspec.lock`、モデルURL・hashは [fixtures/asr-models.json](fixtures/asr-models.json)。重みは Git に入れず、準備時に検証する。

```sh
ASR_AUTOTEST=1 mise run segmented-asr # 共有素材で実接続し、自動終了
mise run segmented-asr              # 実マイク30秒のボタンを表示
```

shared asset の取得は task が `mise run //:test-assets:download` を最初に行う。`tools/prepare_asr.py` が必要なモデルをダウンロードし、元の共有 MP3 から WAV を用意する。別 lab を実行時に import しない。

## 実装の所在

- [asr/app/lib/main.dart](asr/app/lib/main.dart)：record、キュー、区間ID、話者埋め込み、WebRTC送信。
- `asr/app/lib/local/`：[先行音声解析 lab](../../18/flutter-realtime-audio-analysis/README.md) のVAD・話者変化・埋め込み・DSP・ONNXインターフェースをコピーして適応。
- [tools/asr_server.py](tools/asr_server.py)：ChatGPT認証だけで区間単位の音声セッションを作る localhost 制御。Thinkerは起動しない。
- 同じ lab の `demo/external_capture` に消音設定を追加。通常の会話アプリは既定どおり再生する。

## 保存と限界

素材試験は既存の共有会話の認識文字列と区間情報を保存する。実マイク試験の会話文字列は画面だけに保持し、標準出力には件数・時刻・話者ID・状態・音声計測だけを出す。生音声、埋め込み、認証値、SDP、上流call IDは保存しない。

話者のクラスタリングの精度と、ASRの返却を区間IDへ結び付ける正しさは別の評価。短い区間・重なり・話者判定の誤りをASRの結果で埋め合わせない。接続ごとの認証・SDP交換の負荷、直列の待ち時間、発話確定を待つ遅延があり、低遅延の連続ASRとして最適化した構成ではない。長時間、雑音、同時発話、他OSは未検証。

## 実測結果

最初の短い無発声指示では、前後無音を含む20.16秒から VAD が14.528秒を選び、pyannote が6区間に分割した。ECAPA は2話者と判定し、IDは1→2→1→2→1→2。6区間とも文字起こしが得られ、異なる区間IDのイベント・標準 backing turn は0だった。

ただし区間1・3で応答音声が生成され、非ゼロ PCM は99,360 / 22,257 samples。ASR専用としての無発声条件は不合格。他の4区間は差分のみで、user transcript done がなかった。失敗した条件も [最初の結果](results/segmented-asr-shared-first.json) に保存した。

以前5分間の実マイクで無発声を確認した強い指示と、短い指示を区別して再比較する。専用の出力停止パラメーターを使った試験ではない。


強い指示での再試験でも、6区間の文字起こしと話者IDは対応したが、区間4・6で応答音声が生成された（91,744 / 32,779非ゼロsamples）。[強い指示の結果](results/segmented-asr-shared-strong.json) と [保存結果の検算](results/segmented-asr-validation.json) を参照。各条件1回で、応答率の推定はしない。指示を変えて成功するまで繰り返すことはしない。

この構成で区間と話者IDを持つ文字起こしは取得できるが、無発声を必須条件にしたASR専用実装としては未達。以前の長い連続セッションの無発声実績を、この区間別のセッション方式へ一般化できない。今回の指示では応答生成を安定して抑止できず、安定したASR用途には出力生成を構造的に抑止できる経路か、別のASRが必要になる。

実マイクUIは LaunchServices の `open --env` で接続設定を付けて起動する。接続用の環境変数なしにアプリ単体を開くと、取得できても認識用サーバーへ接続できない。重複起動してこの状態になった試行は中止し、実マイク結果には採用しない。
