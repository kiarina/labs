# Voice × Thinker — Mac の会話体験アプリ

## 目的と評価

`record` のマイク PCM → 外部入力トラック → ChatGPT 認証 WebRTC → 自前 Thinker → WebRTC 受信音声 → スピーカー／ヘッドホンを、小さな独立アプリで体験する。prototype は変更しない。

評価は、まず合成音声で委譲・Thinker のツール呼び出し・結果の発話・非ゼロ受信 PCM と出力バッファの消費を確認し、その後本人が実マイクで会話する。合成試験は `record` の実マイクや聴感を検証するものではない。

## 起動

この lab の CLI 0.163.0 と Python 依存を準備し、既存の Codex ChatGPT ログインを使う。Flutter 3.47.2 / Dart 3.13.2、record 7.1.2、flutter_webrtc 1.6.2+hotfix.4。アプリ依存の解決版は `demo/app/pubspec.lock` に保存する。音声 fixture の準備は `say` Kyoko と ffmpeg を使う。

```sh
mise run demo
```

1. ヘッドホンを接続する。
2. 「会話を開始」を押す。マイク使用許可が出たら許可する。
3. 「A17 の予約分を引いた在庫は？」などと話す。
4. 続けて「それを3人で分けると？」などと質問する。
5. 「終了」でマイク取得と接続を閉じる。1回の会話は最大10分。

ミュートはマイク取得を継続して送信を止める。終了は record 自体を止める。カメラは取得も送信もしない。会話文字列は画面とプロセスのメモリに保持し、通常モードでは録音・文字起こしをファイルへ保存しない。OpenAI への送信とサービス側のデータの扱いは別である。

Thinker は独立した Codex gpt-6-luna / low の会話で、同じ接続中は履歴を維持する。一般質問に回答でき、在庫の質問には lab の架空 `lookup_inventory` を使う。ファイル・shell・ネットワークの作業ツールは許可しない。音声側への委譲イベントをアプリが捕捉し、標準 backing thread へは転送しない。

## 実装と境界

- `demo/app/lib/main.dart`: UI、record、WebRTC、ローカル制御。
- `demo/external_capture/`: 先行 lab `b87f868` の Darwin ブリッジを本 lab に写して適応。pub cache や先行 lab を変更しない。
- `tools/demo_server.py`: localhost にだけ bind する制御サーバー。ランダムな接続トークンで保護し、ブラウザー Origin を拒否する。ChatGPT の OAuth 値は Flutter に渡さない。
- `tools/delegation_probe.py`: 同一 lab 内の既存アダプター／Thinker 接続を再利用。

Darwin ADM の受信 PCM を AVAudioEngine / AVAudioPlayerNode に流す再生を追加。未再生キューを上限付きにする。AEC は実装していないのでヘッドホンで試す。スピーカーの回り込み、割り込み中の委譲キャンセル、並行委譲の意味付け、Bluetooth 切替、長時間運転、Mac 以外は未検証。委譲は直列処理する。

アプリは接続時に明示的にマイクを開始する。起動しただけでは録音しない。別アプリのマイク・音量・デバイス設定を変更しない。

## 合成音声による疎通

`VOICE_LAB_AUTOTEST=1 mise run demo` は実マイクを開かず、合成音声をブリッジへ送る。架空の入力・結果・音声メトリクスだけを標準出力へ出し、自動終了する。通常モードでこの出力は行わない。

## 保存した試験結果

[合成音声の結果](results/demo-synthetic-roundtrip.json) は成功。在庫の109個という Thinker 回答と音声文字起こしが対応し、出力の非ゼロ PCM 257,784 samples、再生済みバッファ2,671件、入力ドロップ0、映像0を確認した。実マイク・人が聞いた音声の評価はこの結果に含めない。
