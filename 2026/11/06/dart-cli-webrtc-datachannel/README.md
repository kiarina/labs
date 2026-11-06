# Flutter なしの Dart CLI から WebRTC のデータチャネルをつなぐ（webrtc_dart と libdatachannel の FFI）

Flutter のアプリは flutter_webrtc（libwebrtc）でデータチャネルを張る。同じ相手（libwebrtc と、Python の aiortc）に、**Flutter なしの Dart のプロセス**
（`dart compile exe` の CLI、Linux のコンテナの中も）から同じ形でつなげるかを確かめた（2026-11-06）。

比べた実装は 2 つ:

- [webrtc_dart](https://pub.dev/packages/webrtc_dart) 0.25.3 — Pure Dart（werift の移植）
- [libdatachannel](https://github.com/paullouisageneau/libdatachannel) v0.24.6 — C++ のライブラリを `dart:ffi` で呼ぶ（メディアなし、OpenSSL）。小さな C の shim（`native/ldc_shim.c`）を挟む

相手は 2 つ:

- **Chrome 156**（headless、puppeteer-core）— flutter_webrtc と同じ libwebrtc
- **aiortc 1.15.0** — Python の peer

## 結論

- **libdatachannel を FFI で呼ぶ形なら、Mac でも Linux のコンテナでも Chrome・aiortc とつながる。** offer 側・answer 側のどちらでも、全回成功した（Mac 16/16、コンテナ 8/8）。
  - 往復の中央値は約 0.2 ms（コンテナは約 0.35 ms）。
  - 1 MiB のメッセージの往復は 130〜540 ms、連続送信は 9〜11 MB/s。
  - AOT の CLI は 10 MB、`libdatachannel.so` は 2.9 MB、実行用のイメージ（debian trixie-slim）は 123 MB。
- **webrtc_dart はこのままでは使えない。**
  - aiortc とは 1 回もつながらなかった（DTLS の失敗）。
    - probe が answer のとき（DTLS の client）は、aiortc が分割して送る Certificate を組み立てられない。
    - probe が offer のとき（DTLS の server）は、aiortc に handshakeFailure で断られる。
  - Chrome とは、answer 側なら毎回つながった。offer 側では Mac で 4 回中 3 回、ICE がつながった後に 30 秒で時間切れになった（DTLS の HelloVerifyRequest が繰り返される）。
  - 文字列の送信は ASCII しか通らない（`sendString` が UTF-16 の code unit を 1 byte に切る）。受信は Latin-1 として読まれる。この lab では送るときに `\uXXXX` へエスケープして通した。
  - つながったときの速さも、libdatachannel の約 1/4 だった（1 MiB の往復 約 1.4 秒、2.2〜2.4 MB/s）。
- **相手が消えたのに気づく時間**
  - 相手が丁寧に閉じたときは、どちらの実装も約 1 ms で気づいた。
  - 相手のプロセスを強制終了したときは、libdatachannel が約 16 秒、webrtc_dart が約 4 秒だった（ICE の consent・タイムアウトの既定値の差と思われる。確かめていない）。
- **Docker Desktop for Mac のコンテナから Mac の上の相手へは、相手が Docker の VM 側のブリッジ（192.168.64.1）の候補を出したときだけつながる。**
  - コンテナの候補は 172.17.0.2 だけ。
  - Chrome はメディアの許可が無いと既定の経路のネットワーク（Wi-Fi）でしか候補を集めず、STUN を足しても全部失敗した（0/16）。
  - `--use-fake-ui-for-media-stream` で全部のネットワークから集めると、全部つながった。
  - aiortc は最初から全部のネットワークで集める。
- **アプリの分け方（16000 の UTF-16 単位で `C...` に分割）は、サロゲートペアの途中で切れることがある。**
  - その切れ目の前後が UTF-8 にするときに置き換わり、絵文字が壊れる。
  - 試した大きさでは、65536 文字で 1 回、1 MiB で 9 回が該当した（`dart/tool/split_check.dart`）。
  - libdatachannel はそのまま送るので、該当する回は毎回内容が食い違った。webrtc_dart の回は、エスケープで ASCII になって切れ目が起きなかった。
  - 相手の Python（aiortc 側の実装）はコードポイントで分けるので、この問題は起きない。
  - **アプリ本体（flutter_webrtc）で起きるかは、まだ確かめていない。**

## 調べた形

アプリのメッシュ（`peer.dart`）と同じ約束にした:

- Trickle ICE
  - 自分の候補は、自分の description を送るまで溜める。
  - 相手の候補は、相手の description を設定するまで溜める。
- ordered・reliable のデータチャネルを 1 本（`nerve`）張る。
- シグナリングのメッセージは `{"k":"offer"|"answer","sdp"}` と `{"k":"cand","candidate","sdpMid","sdpMLineIndex"}`。
- ICE サーバーは置かない（同じネットワークの中）。コンテナでは STUN（Cloudflare）ありも試した。
- 1 通のメッセージは `J<json>`。16000 の UTF-16 単位を超えると `C<id>:<i>/<n>:<part>` に分ける。

1 回ごとに次を確かめる（`dart/bin/probe.dart`）:

| 名前 | 内容 |
|---|---|
| open | 相手がそろってからデータチャネルが開くまで |
| rtt_small | 小さなメッセージを 200 回、1 つずつ往復させる（中央値・p95） |
| scripts | ASCII・引用符と改行・日本語・絵文字が同じ形で返るか |
| sizes | 100・15000・16001・65536・262144・1048576 文字の往復。分割がサロゲートペアの途中に来る回は別に記録する |
| burst | 1 KB を 2000 通続けて送り、順番と MB/s を見る |
| remote_gone | 相手に閉じさせる（close: `pc.close()`、kill: プロセスを強制終了）。最初に気づいた合図と時間 |

## 結果

Mac は 1 つの組み合わせごとに、閉じさせる回を 3 回と、強制終了させる回を 1 回流した。コンテナは閉じさせる回を 2 回ずつ流した。数値は成功した回の平均。

### Mac（AOT の CLI）

| 実装 | 相手 | probe の役 | 終わり方 | 成功 | open ms | 往復 中央値 ms | 1 MiB 往復 ms | 連続送信 MB/s | 消えたのに気づく |
|---|---|---|---|---|---:|---:|---:|---:|---|
| libdatachannel | aiortc | answer | close | 3/3 | 49 | 0.23 | 235 | 9.9 | 約 1 ms |
| libdatachannel | aiortc | answer | kill | 1/1 | 48 | 0.22 | 235 | 9.8 | 16.4 秒 |
| libdatachannel | aiortc | offer | close | 3/3 | 53 | 0.21 | 544 | 9.8 | 約 1 ms |
| libdatachannel | aiortc | offer | kill | 1/1 | 54 | 0.24 | 233 | 10.0 | 16.2 秒 |
| libdatachannel | Chrome | answer | close | 3/3 | 90 | 0.20 | 211 | 10.1 | 約 1 ms |
| libdatachannel | Chrome | answer | kill | 1/1 | 90 | 0.20 | 210 | 10.0 | 16.3 秒 |
| libdatachannel | Chrome | offer | close | 3/3 | 93 | 0.19 | 188 | 10.5 | 約 1 ms |
| libdatachannel | Chrome | offer | kill | 1/1 | 87 | 0.18 | 190 | 10.5 | 16.3 秒 |
| webrtc_dart | aiortc | answer | close / kill | 0/4 | - | - | - | - | DTLS: Certificate message truncated |
| webrtc_dart | aiortc | offer | close / kill | 0/4 | - | - | - | - | DTLS: Fatal alert handshakeFailure |
| webrtc_dart | Chrome | answer | close | 3/3 | 124 | 0.24 | 1367 | 2.4 | 約 0.7 ms |
| webrtc_dart | Chrome | answer | kill | 1/1 | 112 | 0.24 | 1371 | 2.4 | 4.0 秒 |
| webrtc_dart | Chrome | offer | close | 1/3 | 212 | 0.27 | 1419 | 2.4 | 約 0.9 ms |
| webrtc_dart | Chrome | offer | kill | 0/1 | - | - | - | - | 30 秒で時間切れ |

### Linux のコンテナ（Docker Desktop for Mac、相手は Mac の上）

| 実装 | 相手 | Chrome が集めるネットワーク | STUN | 成功 | open ms | 往復 中央値 ms | 1 MiB 往復 ms | 連続送信 MB/s |
|---|---|---|---|---|---:|---:|---:|---:|
| libdatachannel | aiortc | - | なし / あり | 8/8 | 48〜60 | 0.37〜0.41 | 232〜434 | 8.6〜9.7 |
| libdatachannel | Chrome | 全部 | なし / あり | 8/8 | 91〜153 | 0.30〜0.35 | 130〜142 | 8.8〜11.4 |
| libdatachannel | Chrome | 既定の経路だけ | なし / あり | 0/8 | - | - | - | - |
| webrtc_dart | aiortc | - | なし / あり | 0/8 | - | - | - | - |
| webrtc_dart | Chrome | 全部 | なし / あり | 8/8 | 108〜226 | 0.33〜0.41 | 1427〜1437 | 2.2 |
| webrtc_dart | Chrome | 既定の経路だけ | なし / あり | 0/8 | - | - | - | - |

各回の JSON は `results/` にある（公開の IP アドレスとホームのパスは `scripts/redact.py` で伏せた）。表は `python3 scripts/summarize.py <macos|docker>` で作れる。

### 分かったこと（実装の上の注意）

- **webrtc_dart**
  - 候補の `sdpMid`・`sdpMLineIndex` が null で出てくる。そのままだと libwebrtc が受け付けない。データだけの offer は m-line が 1 本なので、`'0'`・`0` を入れて送った。
  - `RtcConfiguration` の ICE サーバーの既定は Google の STUN。使わないなら `[]` を明示する。
- **libdatachannel**
  - コールバックはライブラリのスレッドから呼ばれ、文字列はその呼び出しの間しか生きていない。
  - Dart の `NativeCallable.listener` は後で isolate の上で動く。そこで shim で文字列を `malloc` で写し、Dart が `ldc_free` で解放する。
  - データチャネルを作るか、相手の offer を設定すると、自分で交渉が始まる（自動交渉）。description はコールバックで届く。
  - 開いた直後のメッセージが、Dart がチャネルを登録する前に届くことがある。登録までは溜めておく（`impl_ldc.dart` の `_pending`）。
- **Chrome（Mac）**: 失敗した回の後、puppeteer の node が SIGTERM で終わらないことがあった。`run_pair.sh` は子の Chrome ごと強制終了する。

## 環境

- MacBook Pro（Apple M1 Max、64 GB）、macOS 27.0.1
- Dart 3.13.2（Mac）、3.13.7（コンテナ。`dart:3.13.7` で build、実行は `debian:trixie-slim`、Linux 7.0.14-linuxkit、arm64）
- Docker Desktop（Engine 29.9.2）
- Chrome 156.0.8078.80（headless、puppeteer-core 24.27.0、`--disable-features=WebRtcHideLocalIpsWithMdns`）
- aiortc 1.15.0、websockets 17.4、Python 3.14.9
- webrtc_dart 0.25.3、libdatachannel v0.24.6（`NO_MEDIA`・`NO_WEBSOCKET`、Homebrew の OpenSSL / Debian の libssl3t64）

## 動かし方

```bash
mise run setup           # libdatachannel と shim を build、dart・uv・npm の依存を入れる
mise run                 # 手早い確認: libdatachannel（JIT）↔ aiortc を両方の役で
mise run matrix          # Mac の全部の組み合わせ（Chrome が要る）
mise run matrix-docker   # コンテナから（Docker が要る）
```

1 回だけ流すなら `./run_pair.sh <chrome|aiortc> <offer|answer> <close|kill> <label> [probe のコマンド]`。
`PROBE_ARGS="--impl webrtc_dart"` で実装を、`ECHO_ALL_IFACES=1` で Chrome が全部のネットワークで集めるようにできる。

構成:

| パス | 内容 |
|---|---|
| `dart/bin/probe.dart` | 確かめる側の CLI（`--impl webrtc_dart|libdatachannel`） |
| `dart/bin/signal.dart` | 2 者だけを中継する WebSocket のシグナリング |
| `dart/lib/impl_webrtc_dart.dart`・`impl_ldc.dart` | 2 つの実装を同じ口（`rtc.dart`）にしたもの |
| `dart/lib/frames.dart` | アプリと同じ `J`・`C` の分け方 |
| `native/ldc_shim.c`・`scripts/build-libdatachannel.sh` | libdatachannel のコールバックを Dart へ渡す shim と build |
| `peers/browser/`・`peers/aiortc/` | 相手（受けたメッセージを返す） |
| `Dockerfile` | コンテナ用の CLI と libdatachannel |

## 限界と次

- アプリ本体（flutter_webrtc）と、アプリのシグナリングにはつないでいない。相手は同じ libwebrtc の Chrome と、同じ版の aiortc。
- コンテナは Docker Desktop for Mac だけ。Linux のホストの Docker、Windows の Docker Desktop、TURN は試していない。
- 次は、libdatachannel の FFI で body の CLI の入口を作り、アプリと本物のシグナリングにつないで確かめる。
  コンテナからアプリにつなぐときは、アプリ（libwebrtc）が VM 側のブリッジの候補を出すかを確かめる。
