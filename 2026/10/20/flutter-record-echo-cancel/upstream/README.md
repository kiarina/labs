# Upstream report: macOS echoCancel stream is all zeros

`record_macos` 2.1.1（`record` 7.1.2）の `startStream` に `echoCancel: true` を渡すと全サンプルが 0 になる件を、
llfbandit/record へ報告するための材料です。2026-10-20 に [llfbandit/record#633](https://github.com/llfbandit/record/pull/633) として出しました（本文は `draft-pr.md`、head は `kiarina/record` の `fix/macos-voice-processing-channel-map`）。

## 分かったこと

- voice processing を有効にした入力は `9 ch, 48000 Hz, Float32, deinterleaved` で、channel layout は
  `kAudioChannelLayoutTag_DiscreteInOrder | 9`（`0x930009`）。
- この形式から 1ch（または 2ch）へ `AVAudioConverter` を作ると、既定の `channelMap` が `[-1]`（`[-1, -1]`）になる。
  出力のチャンネルにどの入力も割り当てられず、出力は無音になる。普通の 2ch → 1ch なら `[0]`。
- 上流では 2025-07 の [#523](https://github.com/llfbandit/record/pull/523) が「1 チャンネル目をコピーしてから変換」で直していたが、
  2026-02 の [#586](https://github.com/llfbandit/record/pull/586)（stereo を保つ修正）がそのコピーを外し、壊れた（`record_macos` 2.1.x に入った）。
- `main`（`334256c`、未公開の `record_darwin` 2.0.0）でも、`AudioStreamProcessor` と `AudioFileOutput` は tap の形式（9ch）から
  そのまま `AVAudioConverter.make` で変換していて、同じ形になっている。
- 同じ報告・修正の issue / PR は無い（2026-10-20 に検索。近いのは #523・#584・#586・#630）。

## ファイル

- `vp_convert_probe.swift`: Flutter なしで再現する単体の Swift（`swiftc -O vp_convert_probe.swift -o probe && ./probe`、`./probe novp` で対照）。
  マイクの許可が要る。3 通りの変換の peak を出す
- `record_darwin-channel-map.diff`: `main` への修正の案と、マイクの要らない unit test

## 試した結果（MacBook Pro M1 Max、macOS 27.0.1、内蔵マイク、`say` で声を出した）

`vp_convert_probe`:

| | voice processing off | on |
| --- | --- | --- |
| tap ch0 peak | 0.0740 | 0.0624 |
| A そのまま変換（2.1.1 と同じ） | 0.0173 | **0.0000** |
| B `channelMap = [0]` | 0.0173 | 0.0397 |
| C 1 チャンネル目をコピーしてから変換（#523） | 0.0173 | 0.0397 |

`record` の `main` に修正の案を当て、`record/example` の `RunnerTests` を
`xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'` で流した:
71 件すべて通過。足したテスト `testStreamKeepsTheVoiceProcessingChannel` は、修正を外すと失敗する。

## 修正の案の比べ

- **channel map（採用案）**: `AVAudioConverter.make` で、`channelMap` に `-1`（入力なし）があれば `0` に置き換える。5 行、
  tap ごとのコピーと 2 つ目の変換器が要らない。stream とファイル（`AudioFileOutput`）の両方に効く。普通のマイクは `-1` が出ないので動きは変わらない。
  `numChannels: 2` なら 1 チャンネル目が両方に入る
- **1 チャンネル目をコピー（#523 の形）**: 意図が見えやすいが、tap ごとにバッファを作ってコピーし、変換器も別に持つ。
  #586 が外したのと同じ形なので、多チャンネルのマイクの stereo を保つ条件分けがまた要る

## 作者の修正（2026-10-23）

#633 は 2026-10-21 に作者が閉じ、開発中の `feature/route_change` の `3d09e0c` で自分で直した（`channelMap` の `-1` を同じ番号の入力チャンネル、無ければ 0 で埋める。
`numChannels: 2` なら 1・2 チャンネル目を取る点が #633 の案と違う。stream とファイルの unit test 付き）。2026-10-23 に `f4bb8c2` を lab のアプリで実際のマイクに当て、
`echoCancel` で音が出て相手の声が約 33 dB 下がるのを確かめた（`../README.md` の「作者の開発ブランチで確かめた」）。

## 確かめていないこと

- #633 の案そのものを実際のマイクで確かめてはいない（作者の修正 `3d09e0c` は確かめた）
- ファイルへの録音（`start`）で `echoCancel` を使ったときも 0 になるかは、`record` では試していない（同じ変換器を使う）
- iOS の unit test は流していない。iPad では voice processing の入力が 1ch で、`-1` が出ない
- 外付けマイク、ほかの Mac
