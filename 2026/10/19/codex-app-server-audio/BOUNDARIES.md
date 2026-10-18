# 境界指示による文字起こし確定の検証

## 目的と評価方法

ChatGPT認証の既存v3 WebRTC接続で確定操作を試し、使えなければ境界ID付き指示から委譲イベントを要求する。
baselineと境界指示を各1回、同じ共有2話者PCMを実時間送信し、次話者は待たせない。
既存SCD境界を送信時計に従って再生する楽観条件で、今回SCDの推論遅延は含めない。
指示受付・委譲・文字起こし完了を区別し、ID回収、イベント遅延、後着文字、発声を評価する。
実マイク・prototype・Thinkerは使わない。生音声・認証情報・接続IDは保存しない。

## 条件

既存 pin: Codex CLI 0.163.0、Python の aiortc 1.15.0 / websockets 16.0。
macOS 27.0.1 arm64、Apple M1 Max。音声モデルは上書きせず、既存Codex音声経路を使う。
APIキー環境変数を子プロセスから除去し、`account/read` の認証種別を検査する。
共有素材 `tests/assets/mp3/conversation_2speaker_14s_16k.mp3` を PCM16 / mono / 24kHz に変換。
SCD境界は `asr/app/assets/refine-reference.json`。WebRTCはaiortcで送り、既存Flutterのrecordブリッジは今回再実行しない。
音声はWebRTC、指示は認証をそのまま転送するlocalhost sideband adapter経由。
委譲はadapterで捕捉し、標準CodexやThinkerを起動しない。

`mise run boundaries` は実サービスへ接続する。`python3 tools/validate_boundaries.py` は保存済み結果の検算のみ。
CLI の準備は既存READMEに従う。生音声はGitに入れない。

## 根拠と評価上の注意

[OpenAI Docs: Managing sessions](https://developers.openai.com/api/docs/guides/live-conversations#transcript-deltas)
は入力transcriptに完了ターンイベントがなく、時刻は単語境界ではないと説明する。
[Delegation](https://developers.openai.com/api/docs/guides/live-delegation)もtranscriptと委譲の独立性を説明する。
公開イベント名を今回のlegacy Codex経路で使えるとは仮定しない。

CLIの固定ソース `codex-rs/codex-api/src/endpoint/realtime_websocket/protocol.rs`
（lab準備で取得するrust-v0.163.0）にも区間commitのoutbound型はない。
確定操作を推測して大量に試さず、Realtimeの既知操作 `input_audio_buffer.commit` と、
Live形式の候補 `session.input_audio.commit` の2つに絞る。後者は文書化された操作ではない。
両者を音声取得開始前の無音送信中に試し、構文として受理されるか確認する。

最初の比較はPCMに2秒の前置き無音があると誤認した設定ミスで境界が2秒遅れた。
`boundary-*-offset-error.json` に失敗試行を保存し、正しい境界で各1回だけやり直す。
`immediate` は完了待ち条件を外し、channel省略で直接委譲を命じる対照試験。
モデルがASR配信完了を認識できるとは仮定しない。

## 結果

設定修正後の同一14.171秒素材について、baseline、完了待ち指示、即時委譲指示を各1回。
最終区間の末尾でも境界を送るため、境界は話者交代5か所＋音声末尾1か所の計6。

| 条件 | 入力差分 | 指示受付 | ID付き完了イベント | 反射出力の非ゼロ音声 |
| --- | ---: | ---: | ---: | ---: |
| baseline | 41 | 対象外 | 対象外 | 0 |
| 完了待ち指示 | 36 | 6/6 | 0/6 | 0 |
| 即時委譲指示・channel省略 | 39 | 6/6 | 0/6 | 0 |

- `input_audio_buffer.commit`、`session.input_audio.commit` とも `invalid_value` で拒否された。
  エラーの受理可能なtype一覧にもcommit/flushはない。今回のlegacy経路で専用確定操作は使えなかった。
  未公開の別操作・将来版が存在しないとまでは証明していない。
- 完了待ち指示の `session.context.appended` は送信後144〜155ms。
  通知に境界IDを対応付けるフィールドはなく、試験では6件の送信と6件の受付を順序対応した。
  **これは文脈の受付であり、ASR完了ではない。**
- 完了待ち指示でも各区間最後の文字は境界送信から774〜982ms後に到着。
  各受付通知の後に、その通知で終わったはずの区間の文字が5〜9字届いた。
  実際の話者交代5か所に限ると計35字。受付で次話者へ切り替える素朴な方式では84字中35字を誤った話者に割り当てた。
  末尾境界後は最終話者を維持して評価した。句読点は字数から除外。
- baselineの区間末尾文字は境界から997〜1415ms後、即時指示は569〜843ms後。
  各1回で文字列や分割も異なるため、速度改善の因果関係は推定しない。
- 両指示方式で委譲自体が0件だった。完了イベントの遅延は測定不能で、8秒の最終待機でも得られなかった。
  「直ちに委譲」対照も失敗したので、今回のプロンプト・文脈投入経路で任意イベントを確実に発行する方式は成立しない。
  音声依頼からの在庫委譲が成功した別試験とは条件が異なる。

## 解釈と範囲

**境界指示＋受付通知を、文字起こしを区切る仕組みとしては採用できない。**
接続維持の字幕は取得できたが、境界でのASR確定とID付き完了イベントは実証できなかった。
ID付きの委譲完了を待つ本来の方式では全区間の話者確定を保留する必要があり、実用的な確定遅延は達成していない。
WebSocket指示とWebRTC音声のサーバー到着順序も保証されない。

評価の区間は6発話の語句を用いて人手で対応付けた。入力に期待transcriptや語句を渡していない。
SCDは推定境界であり、単語時刻の正解データではない。今回の実験は境界通知後の後着文字を示すもので、
全話者・雑音・重なり発話・長時間・実マイクへの一般化はしない。
指示方式の成否と無音出力の再現性も独立で、今回は非ゼロ出力0だっただけである。

完全な対応には、入力区間に紐づく確定通知を持つASR、区間を独立させる構成、または単語アラインメントなど別の仕組みが必要。
prototypeは未変更。

## 証拠

- `tools/boundary_probe.py`: 最小Python接続・境界送信・イベント採取
- `results/boundary-{baseline,markers,immediate}.json`: 設定修正後の生イベント（文字は共有素材のみ）
- `results/boundary-*-offset-error.json`: 初回設定ミスの結果、採用する比較から除外
- `tools/validate_boundaries.py` / `results/boundary-validation.json`: オフラインで計算する遅延・後着・話者混入

検算の `evidence_valid` は記録の整合性を示し、方式の成功を意味しない。
