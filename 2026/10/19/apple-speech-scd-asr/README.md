# SCD確定区間をApple SpeechAnalyzerとWhisperへ渡す

## 目的と事前評価

同一のSCD確定済み音声区間を独立したASR要求として渡し、最終結果を区間ID・話者IDへ対応付ける。
Whisper small（Macの既存比較対象）とApple SpeechAnalyzer / SpeechTranscriberを、同じ日本語6区間で比較する。
認識CER、区間欠落・別区間への混入、要求開始から確定結果までの時間、初回と後続の差を測る。
音声はまとめて投入し、実時間速度の再送はしない。SCD・VADの推論遅延、録音時間、実マイクは対象外。
各エンジン3パス・6区間。話者交互の正順2パスと逆順1パスで、過去区間の文字や状態の混入も確認する。
事前目安は、非空の区間結果6/6、要求IDと話者IDの保持、正規化CER10%以下、準備後の確定待ちp95が1秒以内。
少数の共有素材の目安であり、製品合格・一般的精度比較ではない。

AppleのモデルassetはOS管理。初回のモデル準備・asset状態と、区間ごとの準備・認識・確定を分ける。
独立要求ごとにAnalyzer/Transcriberを作り、input終了後にfinalizeしてresultsの終了を待つ。
話者IDはローカルの確定済みラベルを引き回すもので、ASRが話者を識別するとは扱わない。

前提: [SCD・話者の検証](../codex-app-server-audio/REFINEMENT.md)、[接続維持ASRの限界](../codex-app-server-audio/TWO_CONNECTIONS.md)。
Swift実装の参考は [SpeechAnalyzer逐次入力lab](../../../07/20/apple-speech-analyzer-streaming-asr/README.md)。実行時に他labをimportしない。
prototypeは変更しない。

## 実マイクの体験アプリ

`mise run demo` でFlutterの小型アプリを起動できる。recordからVAD・SCD・話者埋め込みを通し、SpeechAnalyzerへ確定PCMを直接渡す。操作・計測・制約は [DEMO.md](DEMO.md)。下の比較表は確定済み区間のASR単体であり、体験アプリ全体の表示遅延とは別。 話者変化で早期確定する改良版と旧6秒方式の比較は [STREAMING.md](STREAMING.md)。

## 条件と再現

- Apple M1 Max、macOS 27.0.1（26A434）、Swift 6.4、Dart 3.13.2。詳細は `results/environment.json`。
- 共有素材: `tests/assets/mp3/conversation_2speaker_14s_16k.mp3`。FFmpegで16kHz mono PCM16へdecodeし、14.171秒の同じPCMから切り出す。
- `fixtures/scd.json` は先行lab `codex-app-server-audio` の保存済み6区間。話者IDは区間に付いたローカルラベルを引き回す。今回SCD/ECAPAを再推論せず、その正しさはASR比較の採点対象外。
- `fixtures/reference.txt` は共有会話6発話の正解文。区間境界はSCD推定値で、音素・単語境界の正解ではない。
- Apple: `SpeechTranscriber` 日本語 `ja_JP`、preset `.transcription`。assetは既にinstalledで、今回ダウンロードは発生していない。OS管理のモデル重みの版・hashは固定できない。
- Whisper: `whisper.cpp` tag **v1.9.5**、multilingual **small f16**、Metal＋Accelerate、threads=4、greedy、language=ja、no_context=true、suppress_nst=true、temperature=0、audio_ctx=0（30秒の通常context、fit短縮なし）。温度fallbackはupstream既定のまま。
- Whisperのtagとshimは先行のFlutter audio labと比較を合わせるため維持する。backend文字列は同tagのビルドでも `v1.9.5-dev` と報告される。準備scriptがarchiveと重みのSHA-256を検査する。
- shimの来歴: `flutter-realtime-audio-analysis/packages/whisper_cpp/src` を本labの `native/` へコピー。以降本labが所有し、sibling import・共有cacheの編集はしない。ライセンスは `native/LICENSE` と取得するupstream LICENSE。

```sh
# 実際にローカルのモデルを動かす。初回はWhisper source/重みと必要ならApple assetを取得
mise -C 2026/10/19/apple-speech-scd-asr run run

# 保存済み結果だけを検算。モデル実行・ネット接続なし
mise -C 2026/10/19/apple-speech-scd-asr run
```

必要な道具はXcode Command Line Tools、Swift、Dart、Python 3.13以降、FFmpeg、CMake。
`tools/prepare.py` は共有素材からWAVを作り、Whisperのshimをdylibとして本lab内にbuildする。
モデル・音声・build生成物は `.gitignore` の対象。今回の比較はAppleの18要求を先に、Whisperの18要求を後に実行した。
同時実行ではなく、エンジン間の実行順序はcounterbalanceしていない。熱・OSキャッシュ等の差は除去できていない。
各エンジン内の区間順は正順2回・逆順1回で、同じモデルのロードを保ち、ASRの過去テキストは入力しない。

## 結果

| 指標 | Apple SpeechAnalyzer | Whisper small |
| --- | ---: | ---: |
| 非空結果・区間/話者ID一致 | 18/18 | 18/18 |
| 正規化CER（各6区間、各試行とも同値） | **2.33%**（2/86字） | **6.98%**（6/86字） |
| 要求→確定の中央値（18件） | **95ms** | **144ms** |
| 同p95（18件） | 125ms | 234ms |
| 最初の要求 | 248ms | 650ms |
| 最初を除く17件の中央値 / p95 | 95 / 103ms | 143 / 158ms |
| 別計測の初期準備 | installed assetの確認等66ms | モデルロード5.28秒 |

要求→確定には、区間WAVの読み取り・入力変換・Analyzerの作成/準備（Apple）、推論、
最終確定と結果streamの終了待ちを含める。Whisperのcontext生成/モデルロードとAppleのasset確認等は別に示す。
「最初」はプロセス内の最初の要求であり、OSのモデルキャッシュを消した完全cold startではない。
録音/SCD確定待ち、VAD先読み、音声ファイルの切り出し、Flutter UIの描画は含めない。
Appleの単語レベル時刻精度は評価していない。表のp95は18件だけの標本で、長時間のtail latency保証ではない。

Appleの主な誤りは最後の「正解だった」が「正解だ」になるもの。Whisperは「改札」を「解説」、
「助かる」を「助かれ」、「ほんと」を「本当」とするなどの差があった。
正規化はUnicode NFKC・小文字化・空白と句読点の除去だけで、漢字/かなや数詞を意味で同一視しない。
「ほんと／本当」のような表記差もCERに含まれるため、CER差を意味理解の差と読み替えない。

正順・逆順とも各区間に対応する内容が得られ、別区間の文を持ち越す例は今回見られなかった。
ただしID一致の構造的確認と、正解文とのCERは別の判定であり、IDを保持しただけで認識正確とはしない。
SpeechAnalyzerは各区間の入力終端を明示し、`finalizeAndFinish(through:)` と results終了を待って次の要求へ進む。
今回各要求は最終結果1件で、partialを最終イベントとして重複登録する問題はなかった。

## Dartからの1要求ごとの往復

`tools/dart_stream.dart` → 常駐Swift helper `--serve` のstdin/stdout JSONLで、
入力区間を1件ずつ送り、結果が届いた時点で区間IDと話者IDを検査した。正順6件＋逆順6件。
期待文はnative helperへ渡さない。音声は既存のローカルWAVとして渡す最小実証で、マイクは取得しない。

- helper準備完了まで: 361ms（installed asset、別の短い統合試験）
- 12要求のID一致: **12/12**
- Dartからの送信→確定返信: 中央値 **99ms**、p95 約 **123ms**、最大 **146ms**
- nativeの処理だけでなくstdin/stdoutとJSON受け渡しを含む。初期起動は別計測。

このhelperは区間ごとにプロセスを起動し直さない。試験終了時にはstdinを閉じて終了する。
本labのprocess bridgeはFlutter pluginを実装したことを意味しない。
メモリPCMを直接渡すPigeon/MethodChannel/FFI、sandbox・署名・配布、デバイス切替は別途必要。

## 判断と限界

**SCD確定区間 → OS標準ASR → 最終結果を区間ID・話者IDに戻す構成はMacで成立した。**
この短い素材ではWhisper smallよりCERが低く、確定待ちも短かった。事前目安も両エンジンとも通った。
入力終端を明示できるため、連続音声の遅れて来た差分を別話者区間へ分け直す必要はない。
話者IDはASRの推測ではなく、その独立要求に保持したラベルであり、誤ったSCDラベルを直すものではない。

日本語14秒・6発話のみで、短い会話の結果を長文・雑音・固有名詞・実マイク・同時発話へ一般化しない。
3回の反復は応答と順序変更の確認で、異なる18発話の独立精度試験ではない。
既存パイプライン全体では区間確定待ちが別に加わるため、字幕が約100msで出るという意味ではない。
モデルの違うWhisper base/medium/largeやfit_audio_ctx設定の比較、iOS、Windows、Android、Webは未検証。
Apple assetが未取得の環境での初期取得時間、長時間連続/メモリ、同時要求・再利用、停止中断、無音区間の挙動は未確認。
prototypeへの組み込みは行っていない。

## 証拠と参照

- `results/apple.json` / `results/whisper.json`: 3パス×6要求の認識結果と時間。
- `results/dart-stream.json`: 常駐helperとの12要求の往復。
- `results/comparison.json`: CER、待ち時間、ID整合性のオフライン検算。
- `fixtures/segments.json`: サンプル境界、区間ID、話者ID、正解文、PCM hash。
- `results/environment.json`: OS/toolchain条件。音声は共有素材だけで、人の会話文や認証情報は保存しない。
- [Apple SpeechAnalyzer](https://developer.apple.com/documentation/speech/speechanalyzer)
- [Apple: SpeechAnalyzerの紹介](https://developer.apple.com/videos/play/wwdc2025/277/)
- [Whisper.cpp](https://github.com/ggml-org/whisper.cpp/tree/v1.9.5)

初回のSwift buildはlocale引数の渡し忘れで失敗し、修正してbuildした。比較の認識結果を得る前の実装ミスで、認識条件の変更ではない。
