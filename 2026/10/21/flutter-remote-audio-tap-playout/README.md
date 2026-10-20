# 受信 PCM の正式な口（fork の remote audio tap と bridge の ReceivedAudio）

前の 2 つの lab（[受信音の加工の口](../../20/flutter-fork-gpt-live-codex-playout/README.md)、[MeanVC2](../../20/flutter-gpt-live-codex-meanvc2-playout/README.md)）は、
受信トラックの PCM を flutter_webrtc の内部（macOS `remoteTrackForId:`、Windows `peerconnections_`）から取り出していた。
その口を fork と bridge の公開 API に作り、lab の plugin から flutter_webrtc の内部への依存を外して、同じ結果になることを Mac・Windows で確かめた（2026-10-20〜21）。

## 結論

- **口は 2 つに分けた。** native の部分は fork（`RTCRemoteAudioTap`、topic `codex/remote-audio-tap` `dc4b260`、上流の `main` から切った提案。利用のブランチ `fce2727` に merge）、
  48 kHz mono への変換は bridge（`ReceivedAudio`、0.1.0-dev.3 `88903a6`）。
  - fork に置く理由: 受信トラックを探すには plugin の中の表が要り、「受信トラックの復号した PCM を受け取る」は上流に出せる汎用の機能だから。上流には形式を変えない（SDK が渡すレート・チャンネルのまま）最小の口として出せる。
  - bridge に置く理由: 送信の側（外部入力）と対になる製品向けの便利な部分（mono・48 kHz・件数）。fork の公開 API だけを使い、デバイスもミキサーも AEC も持たない。
- **口が持つこと:** ミキサーの音量の前の PCM（macOS `RTCAudioRenderer`、Windows `AudioTrackSink`）、トラックの音量を 0 にして native の再生を無音のまま復号を回し続けること、
  外した時の音量の戻し。音声のスレッドは `try_lock` で上限 1 秒の作り置きのバッファに写すだけで待たず、別のスレッドが 10〜20 ms ごとに Dart へ送る。ミキサーや AEC の方式には縛られない（PCM を渡すだけ）。
- **同じ結果になった。** 偽の peer で、鳴らした音（加工後）を参照にするとエコーが下がり、加工前の参照では下がらない。

| | 素通し 加工後 / 加工前 | ピッチ変更 加工後 / 加工前 | VC（MeanVC2）加工後 / 加工前 |
|---|---|---|---|
| Mac（3 ステップ） | 20.2 / 20.2 dB | 17.3〜18.5 / 3.2〜3.6 dB | 12.3〜16.6 / 0.8〜2.3 dB |
| Windows（2 ステップ） | 11.7 / 11.7 dB | 11.1 / 1.7 dB | 14.1〜15.5 / 0.9〜1.3 dB |

- macOS の native の出力（fork の出力専用の装置）は全区間 0。Windows は、ピッチ変更のときマイクと加工前の音の相関が 0.055 で、native の再生は漏れていない。
- 口の数字: Mac は 6564 回で 3,149,760 フレームを渡し、ロックが取れずに捨てたのは 1 回（480 フレーム）、あふれ 0。Windows は 6536 回で 3,137,280 フレーム、捨てた分 0。
- **Dart を経由する分の遅れ:** Mac の素通しの「受け取ってから鳴らすまで」が中央値 27 → 41 ms（95% 68 ms、最大 110 ms）、待ち行列が空になった回が 7 → 14 回。
  Windows は 30 ms のまま（WASAPI がまとめて引くので待ち行列の見え方が違う）。VC のときはどちらも 650 ms 前後で変わらない。

## 作り

```text
受信トラック ─ fork RTCRemoteAudioTap（sink・音量 0）─ event channel ─ bridge ReceivedAudio（48 kHz mono）─ Dart
  └─ native の再生は無音で回り続ける（復号を進める）                                         │
lab の plugin ← pushReceived ←──────────────────────────────────────────────────────────────┘
  └ 加工の口（素通し・遅延・ピッチ・VC）→ アプリのスピーカー → 鳴らした音を AEC3 の参照
```

lab の `playout_audio` は flutter_webrtc に依存しなくなった（受信は `pushReceived`、スピーカーは `startSpeaker`）。ほかは前の MeanVC2 の lab と同じ。

## 動かし方

前の MeanVC2 の lab と同じ（`mise run`、`vc/` の VC のサーバー、`tools/peer.py`、`mise run launch-macos`、Windows は `tools/windows/build.cmd` と `launch.ps1 -Vc`）。
Windows の pub cache は lab ごとに分ける（`set LAB_PUB_CACHE=%USERPROFILE%\work\gpc21`）。前の lab と共有した pub cache では、依存の一覧が欠けてビルドが止まった。

## 成り立つ範囲と残り

- 偽の peer だけ。本物の通話（gpt-live-1-codex）と人の聴取は、前の lab の口で済ませていて、この口では流していない。Dart を経由する分の途切れ（Mac で 14 回）が聞いて分かるかは未確認。
- 上流への Pull Request はまだ出していない（オーナーに見せてから）。Linux・iOS・Android・Web は実装していない（Linux と eLinux の CMake には足した）。
- Windows は音量の読み取りの API が無いので、外した時は SDK の既定の 1 に戻す。
- `try_lock` が取れなかった分は捨てる。配信のスレッドがバッファを入れ替える一瞬とぶつかったときに起きる（Mac で約 65 秒に 1 回、10 ms）。

依存と版は [results/pins.json](results/pins.json)、結果は [Mac](results/mac-tap-fake-1.json)・[Windows](results/win-tap-fake-1.json)・[口の数字と遅れ](results/tap.json)。有料の API は呼んでいない。
