# ChatGPT ログインで自前 Thinker へ委譲し、音声で返す

ChatGPT 認証だけで、音声モデルが発行した委譲をアプリ所有の Thinker に渡し、ツールで調べた結果を同じ委譲へ返して音声応答を得られた。prototype は変更していない。

## 検証した構成

```text
合成音声の依頼 ──WebRTC──> Codex 音声セッション
                              │ delegation.created
                         sideband adapter（lab）
                              │
                      独立した Thinker プロセス
                      Codex / gpt-6-luna / low
                              │ lookup_inventory
                      アプリ所有の架空在庫ツール
                              │ 計算した回答
                         sideband adapter
                              │ delegation.context.append
Codex 音声セッション ──WebRTC──> 回答音声・文字起こし
```

音声・Thinker の両方で `account/read` が `chatgpt` を返した。子プロセスから `OPENAI_API_KEY` を除外し、API キーへのフォールバックは使わない。認証設定・グローバルなモデルキャッシュは変更しない。

音声側は CLI 0.163.0、v3、`outputModality: audio`、`clientManagedHandoffs: true`、`includeStartupContext: false`。call 作成先は `experimental_realtime_webrtc_call_base_url="https://chatgpt.com/backend-api/wham"`。音声モデルは上書きしない。

sideband の接続先だけを `experimental_realtime_ws_base_url` で localhost のアダプターへ向け、アダプターが既存の `wss://api.openai.com/v1/live/[call-id]` に中継する。WebRTC のメディアは直接接続のまま。標準 CLI のソースやバイナリーは変更していない。

## 実測結果

2026-10-19、MacBook Pro M1 Max、合成音声による1回の試験。実マイクは使っていない。

| 段階 | 結果 |
| --- | --- |
| 音声の依頼 | 商品コード A17 の在庫を調べ、予約分を引いた利用可能数を日本語で回答する |
| 音声モデルの委譲 | 実際の `delegation.created` を1件受信 |
| Thinker の処理 | `lookup_inventory({"product_code":"A17"})` を1回実行 |
| ツールの値 | 在庫137、予約28。アプリが fixture を読み返す |
| Thinker の回答 | 商品コードA17の予約分を引いた利用可能数は109個です。 |
| 音声側の回答文字起こし | A17の利用可能数は109個です。 |
| 結果返却後の音声 | 非ゼロ PCM 347,240 samples、peak 8,342 |
| 音声側の標準 backing thread | turn 0件。別プロセスの Thinker が処理 |
| Thinker 処理時間 | 4.731秒 |
| 試験全体 | 22.36秒 |

137・28・109は音声の依頼に含めていない。回答の109を事前注入せず、別 Thinker のツール利用と計算を通して得た。`appendSpeech` で回答を読み上げさせる代替試験でもない。実際に受け取った委譲 ID に結果を結び付けて返した後、回答の文字起こしと非ゼロの受信音声を確認した。音声の聴感評価は行っていない。時間は単発の観測値であり性能保証ではない。

## アダプターが必要な理由

標準 Codex の handoff は backing Codex thread へ自動ルーティングされる。`clientManagedHandoffs` だけでは、この入力側のルーティングを止められない。lab は上流の実際の委譲イベントを捕捉し、標準ルートへ転送せず、自前 Thinker に渡すことで重複処理を防いだ。他のイベントは中継する。

結果の返却はこの CLI の legacy wire schema を使う。

```json
{"type":"delegation.context.append","delegation_item_id":"<受信したID>","channel":"commentary","content":[{"type":"input_text","text":"<Thinkerの回答>"}]}
```

公開 Live API の現行 delegation イベントや attach URL とは世代が違う。[BACKEND_COMPARISON.md](BACKEND_COMPARISON.md) の一次資料・実装確認と合わせて扱う。

## 再現と保存結果

- [実行コード](tools/delegation_probe.py)、[在庫 fixture](fixtures/delegation-inventory.json)
- [保存結果](results/thinker-delegation-roundtrip.json)、[オフライン検算](results/thinker-delegation-validation.json)
- [音声準備](tools/prepare_delegation.sh)、[検算コード](tools/validate_delegation.py)

既存 lab の CLI と Python 依存を準備した上で実行する。音声準備には macOS の `say`（Kyoko）と ffmpeg が必要。Thinker のモデル情報は既存の `~/.codex/models_cache.json` から gpt-6-luna のみ読み、直接の dynamic tool 呼び出し用にローカルコピーを作る。この派生カタログ・音声 fixture・生ログは無視対象の `work/` 内だけに置く。

```sh
mise run delegation-probe  # 明示的に選ぶ実接続。ChatGPT の利用枠を消費する
mise run                  # 保存結果の検算のみ。接続・推論を繰り返さない
```

保存するのは架空の依頼・回答・在庫と計測値。OAuth 値、SDP、IP、実際の call / thread / delegation ID、モデルカタログ全文は保存結果に残さない。認証ヘッダーは中継時のメモリ上だけで扱う。

## 残る検証範囲

独立 Thinker はアプリが起動・管理する Codex プロセスである。Claude、kiapi、リモートサーバーなど別実装の Thinker は未検証。今回のアダプターは単一委譲向けで、並列委譲、途中の訂正・割り込み・キャンセル、長時間運転、切断復帰は未検証。prototype への組み込みは保留のまま。

今回の疎通から、全アカウントの利用可否、課金内訳、商用・ホスト型サービスでの認証利用条件は確定しない。これらは [比較文書](BACKEND_COMPARISON.md#認証の利用範囲と未確認事項) を参照する。
