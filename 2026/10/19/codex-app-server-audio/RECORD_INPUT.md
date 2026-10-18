# record 外部入力ブリッジと ChatGPT WebRTC の接続候補

## 判定の範囲

2026-10-19、先行 lab の確定した実証版 `b87f868` を照合した。

[外部入力の先行 lab](../flutter-webrtc-external-capture/README.md) が作る通常の音声トラックを、この lab の Mac 体験アプリで ChatGPT 認証 WebRTC の入力へ接続した。実装・合成音声の往復・本人の実マイクでの体験確認は [DEMO.md](DEMO.md) を参照。prototype には組み込まない。

先行 lab は `record.startStream` の PCM16 / 48 kHz / mono を `CaptureBridge.pushAudio` へ渡し、ネイティブ WebRTC の音声トラックを生成する。Mac・Android・iOS・Web のローカル送受信結果が保存されている。Windows も合成 PCM および実マイクの `record` 音声を独立した Chrome 受信側で復号できたが、WebRTC の既定 ADM が追加のマイク取得を試みる制約が残る。`record` だけのマイク所有を保証するには wrapper / factory の拡張が必要。Windows の実カメラ取得と、追加マイク取得を抑止した構成は成立済みと扱わない。詳細は先行 lab の README / Windows notes を正典とする。

本 lab はアプリが作った SDP offer を `thread/realtime/start` の `transport: {type: "webrtc", sdp: ...}` に渡し、`thread/realtime/sdp` の answer をアプリの peer に設定している。接続オブジェクトやデバイス制御を app-server に渡す方式ではない。

## 接続する場合の変更点

1. 先行 lab の実証版 `b87f868` の必要なブリッジと依存・patch を本 lab 内へ適応する。別 lab のソースを直接 import しない。製品コードは触らない。
2. Darwin の外部音声デバイスを WebRTC の初期化より先に設定する。`record` だけがマイク取得を所有する。新しいアプリの初期化順序にこの制約を反映する。
3. 作られた stream の `getAudioTracks()` だけを送信 peer へ追加する。カメラ取得も映像トラック送信も不要。
4. `oai-events` data channel を作り、ICE 候補を含む local SDP offer を取得する。ローカル loopback の相手 peer を、ChatGPT 認証の app-server の SDP answer に置き換える。call 作成先・v3 / audio の条件は本 lab と同じにする。
5. `record` の PCM をブリッジへ流す。48 kHz PCM を WebRTC が符号化するため、既存 Python fixture の24 kHzに合わせてリサンプルする必要があるとは限らない。PCM を `appendAudio` に重複送信しない。
6. 無発声の文字起こしを先に確認する。送信 RTP 統計だけで成功とせず、既知の試験文に対応した上流の入力文字起こしを受け取る。
7. gate の on/off と再開時の flush、取得を開き直さないこと、終了時の cleanup を確認する。

認証・制御はローカル app-server に残す。Flutter Web / Mobile を対象にする場合は、app-server を動かすホストとの制御経路が別途必要であり、OAuth トークンをブラウザーへ渡す構成を前提にしない。最初の接続候補は macOS の独立 lab アプリ。

## 音声応答を扱う際の追加条件

先行 lab の Darwin 用カスタム音声デバイスは受信音を pull して捨てる実装で、スピーカー再生は行わない。このままでも入力の文字起こし・受信 PCM の観測は候補になるが、Mac 体験アプリでは受信 PCM の再生経路を追加した。

AEC / NS / AGC、スピーカーからの回り込み、二重取得、長時間運転、デバイス切替は別の評価項目。先行 lab のローカル送受信成功から ChatGPT 相手の双方向会話の成立までは断定しない。

区間を確定してから個別接続へ送る ASR の実測は [SEGMENTED_ASR.md](SEGMENTED_ASR.md) を参照。この方式は話者IDとの結び付けを確認できた一方、無発声が安定せず、本人が待ち時間を実用に不向きと評価したため採用しない。会話体験アプリの成功と、ASR専用としての採用判断を区別する。
