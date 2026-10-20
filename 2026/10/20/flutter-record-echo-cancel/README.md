# What record's echoCancel actually does on macOS, iOS, Android and Web

Flutter の [`record`](https://pub.dev/packages/record) 7.1.2 の `startStream` で、`echoCancel` を有効にしたときに、
同じ端末のスピーカーから流した声（相手の声＝消したい音）と、部屋の人の声（残したい音）がマイクにどれだけ入るかを、
macOS・iOS・Android・Web の実機の本物のマイクとスピーカーで測りました。

前の lab [flutter-record-camera-senses](../../../09/26/flutter-record-camera-senses/README.md) では、macOS で `echoCancel` を
有効にすると音がすべて 0 になり、原因は未特定でした。その原因を突き止め、直した場合に効くかも確かめます。
Windows は `record` の実装が `echoCancel` を使っていない（前の lab でソースを確認）ので、対象から外しました。

## 問い

1. `echoCancel: true` で、相手の声（同じ端末のスピーカーの音）は減るか。プラットフォームごとに何が要るか
2. そのとき、部屋の人の声は残るか。相手と人が同時に話す（ダブルトーク）とどうなるか
3. macOS で音が 0 になる原因は何か。直せるか

## Findings

- **macOS: `record_macos` 2.1.1 のままでは使えない。原因は `record` の変換で、Apple の voice processing ではない。**
  voice processing を有効にすると入力が **9 チャンネル・48 kHz**（Float32）になり、tap には音が届いている（peak 0.01〜0.06）。
  `record` はこれを `AVAudioConverter` で 9 → 1 チャンネルへ変換していて、その結果が全サンプル 0 になる。
  9 チャンネルはどれも同じ値で、**1 チャンネル目だけを取り出してから変換すると音が出て、エコー除去も効く**
  （相手の声の相関 0.74 → 0.14〜0.17、音量 -30 → -51〜-60 dBFS。人の声は残り、むしろ +6 dB）
- **iOS（iPad Air 4）: `echoCancel` だけで効く。** 相関 0.61〜0.65 → 0.11〜0.26、音量 -21 → -51〜-57 dBFS。人の声は残る
- **Android（Pixel 6）: `echoCancel` だけでは効かない（相関 0.53 → 0.54〜0.55）。** 入力を `voiceCommunication`、
  モードを `inCommunication`、再生も通話用にそろえ、**そのうえで `echoCancel` を有効にすると効く**（`voice-ec`: -46.5 dBFS・相関 0.25、
  `voice-ec-ns-agc`: -68〜-69 dBFS・相関 0.14〜0.15）。通話用の経路だけで `echoCancel` を無効にした `voice-raw` は効かない
- **Web（Chrome 155）: `echoCancel` だけで効く。** 相関 0.73 → 0.05〜0.08、音量 -32.5 → -55〜-56 dBFS。人の声は残る
- **ダブルトーク（相手と人が同時）では、相手の声の相関が 0.15〜0.24 まで下がり、人の声の相関はたいてい raw（0.22〜0.28）と同程度か
  それ以上に残った。** ただし下回った回もあり（iOS の ios-1 `ec` 0.16、Android の android-1 `voice-ec-ns-agc` 0.18）、回ごとの揺れが大きい
  （Android の `voice-ec-ns-agc` は 0.18 と 0.40）

相関の目安: 流した元の音の包絡との正規化相互相関で、1 に近いほど元の音がそのまま入っている。相手の声と人の声の元の音どうし
（無関係な声）でも 0.27 が出るので、**0.15〜0.25 は「ほぼ入っていない」と読む**。

## 方法

### 信号と流し方

- 声は共有のアセット `tests/assets/mp3/conversation_2speaker_14s_16k.mp3` から切り出した（`mise run prepare`）。
  相手の声 `far.wav` は 0〜6 秒、人の声 `near.wav` は 7.5〜13.5 秒（どちらも 16 kHz モノラル、2 人の会話）
- 測る端末（DUT）が相手の声を自分のスピーカーで流し、**別の端末（helper）が人の声を流す**（部屋にいる人の代わり）。
  helper は、DUT が Mac・Web のときは Pixel 6（このアプリの helper 役）、DUT が iPad・Pixel 6 のときは Mac（`afplay`）
- 1 つの設定につき 27 秒の枠を 1 本の録音で取る。時刻は各端末の時計（epoch ms）で合わせる

  | 枠の中の時刻 | 何が鳴るか |
  | --- | --- |
  | 1.5〜3.5 秒 | 何も鳴らさない（無音時の音量） |
  | 3.5〜9.5 秒 | DUT が相手の声だけ |
  | 10.5〜16.5 秒 | helper が人の声だけ |
  | 17.5〜23.5 秒 | 両方同時（ダブルトーク） |

- 各区間で、録音の 1 kHz 包絡と元の音の包絡の正規化相互相関の最大値を取り、その位置で元の音の長さ分の音量（dBFS）を測る。
  探す遅れの幅は、DUT 自身の音は -0.2〜+1.0 秒、helper の音は端末間の時計のずれを見込んで ±2.5 秒
- アプリの起動直後の最初の `startStream` は数秒〜11 秒遅れることがあった（macOS）ので、最初の枠の前にマイクを一度開いて閉じる

### 設定

| 名前 | `echoCancel` | `noiseSuppress` | `autoGain` | Android の通話用の経路 |
| --- | --- | --- | --- | --- |
| raw | | | | |
| ec | on | | | |
| ec-ns-agc | on | on | on | |
| voice-raw（Android） | | | | on |
| voice-ec（Android） | on | | | on |
| voice-ec-ns-agc（Android） | on | on | on | on |

Android の通話用の経路: `AndroidRecordConfig(audioSource: voiceCommunication, audioManagerMode: modeInCommunication, speakerphone: true)`、
再生は `audioplayers` の `AudioContextAndroid(usageType: voiceCommunication, audioMode: inCommunication, isSpeakerphoneOn: true)`。
iOS の録音は `IosRecordConfig(categoryOptions: [defaultToSpeaker, mixWithOthers])`、再生は `playAndRecord`・`defaultToSpeaker`・`mixWithOthers`。

### macOS の修正（lab の中だけ）

`app/packages/record_macos` は `record_macos` 2.1.1 を写したもので、`dependency_overrides` で使う。環境変数
`ECHO_RECORD_MACOS_PATCH` が空なら公開版と同じ動きで、次の切り替えを足した（差分は `patches/record_macos-2.1.1-lab.diff`）。

- `mono`: tap の形式のチャンネル数が 2 以上なら、1 チャンネル目だけを取り出して、モノラルの形式として変換器へ渡す
- `mixer`・`format`: 当初の見当（出力側を graph に入れる、`outputFormat(forBus:)` で tap する）。原因が分かったので測っていない
- 形式と tap ごとのチャンネル別の peak を `ECHO_PATCH`・`ECHO_TAP` の行で出す（結果の `macPatchLog`）

### 環境

- Flutter 3.47.2、`record` 7.1.2（`record_macos` 2.1.1、`record_ios` 2.1.1、`record_android` 2.2.0、`record_web` 2.1.3）、
  `audioplayers` 6.8.1。すべて release ビルド
- macOS: MacBook Pro M1 Max、macOS 27.0.1、内蔵マイクとスピーカー、出力音量 50
- iOS: iPad Air 第 4 世代、iPadOS 27.0.1、内蔵マイクとスピーカー（音量は記録できていない）
- Android: Pixel 6、Android 17（CP2A.260705.006）、メディアの音量 19/25、ワイヤレスデバッグ
- Web: Google Chrome 155.0.8059.85（macOS、上の Mac の内蔵マイクとスピーカー）、`--use-fake-ui-for-media-stream`（許可だけ自動、
  デバイスは本物）と `--autoplay-policy=no-user-gesture-required`
- 同じ部屋、端末どうしは数十 cm。Android と Mac の時計の差は 282〜307 ms

## Results

数値は `results/*.json`。表は `python3 tools/summarize.py <files>` の出力。「non-zero」は 0 でないサンプルの割合、
「mic late」は枠の開始からマイクの最初のサンプルまでが 1.5 秒を超えた回（無音区間などが欠けるので、その行は比べない）。

| run | variant | non-zero | silence dBFS | far dBFS / corr | near dBFS / corr | DT far corr | DT near corr |
| --- | --- | --- | --- | --- | --- | --- | --- |
| macos-try1 | raw | 100% (mic late 2961 ms) | -52.1 | -29.2 / 0.73 | -47.5 / 0.42 | 0.71 | 0.28 |
| macos-try1 | ec | 0% | — | — / 0.00 | — / 0.00 | 0.00 | 0.00 |
| macos-try1 | ec-ns-agc | 0% | — | — / 0.00 | — / 0.00 | 0.00 | 0.00 |
| macos-patch-none | ec | 0% (mic late 3369 ms) | — | — / 0.00 | — / 0.00 | 0.00 | 0.00 |
| macos-patch-mono | raw | 99% (mic late 11244 ms) | — | -30.2 / 0.00 | -30.2 / 0.29 | 0.73 | 0.22 |
| macos-patch-mono | ec | 55% | -54.8 | -53.6 / 0.16 | -42.7 / 0.50 | 0.20 | 0.28 |
| macos-patch-mono | ec-ns-agc | 61% | -55.9 | -48.9 / 0.14 | -39.8 / 0.54 | 0.21 | 0.26 |
| macos-mono-1 | raw | 100% | -52.1 | -30.1 / 0.74 | -48.7 / 0.42 | 0.74 | 0.27 |
| macos-mono-1 | ec | 56% | -54.9 | -51.2 / 0.17 | -42.2 / 0.52 | 0.22 | 0.24 |
| macos-mono-1 | ec-ns-agc | 59% | -55.5 | -48.4 / 0.15 | -39.3 / 0.53 | 0.21 | 0.26 |
| macos-mono-2 | raw | 100% | -52.6 | -30.1 / 0.73 | -48.8 / 0.41 | 0.74 | 0.27 |
| macos-mono-2 | ec | 53% | -54.2 | -60.5 / 0.14 | -42.2 / 0.52 | 0.23 | 0.26 |
| macos-mono-2 | ec-ns-agc | 62% | -55.8 | -52.6 / 0.17 | -39.7 / 0.47 | 0.18 | 0.19 |
| ios-1 | raw | 100% | -55.2 | -20.6 / 0.61 | -43.2 / 0.58 | 0.60 | 0.23 |
| ios-1 | ec | 98% | -55.4 | -51.1 / 0.26 | -40.2 / 0.41 | 0.15 | 0.16 |
| ios-1 | ec-ns-agc | 78% | -49.6 | -50.9 / 0.19 | -41.6 / 0.51 | 0.20 | 0.35 |
| ios-2 | raw | 100% | -55.1 | -20.9 / 0.65 | -42.5 / 0.57 | 0.64 | 0.25 |
| ios-2 | ec | 77% | -55.3 | -56.5 / 0.11 | -43.5 / 0.52 | 0.20 | 0.35 |
| ios-2 | ec-ns-agc | 76% | -54.9 | -47.4 / 0.15 | -43.1 / 0.51 | 0.22 | 0.32 |
| android-1 | raw | 99% | -49.2 | -30.6 / 0.53 | -46.1 / 0.45 | 0.53 | 0.23 |
| android-1 | ec | 99% | -52.1 | -30.7 / 0.55 | -46.8 / 0.53 | 0.53 | 0.23 |
| android-1 | ec-ns-agc | 99% | -51.4 | -30.7 / 0.55 | -46.5 / 0.51 | 0.51 | 0.23 |
| android-1 | voice-raw | 100% | -48.7 | -22.7 / 0.58 | -42.3 / 0.56 | 0.54 | 0.27 |
| android-1 | voice-ec-ns-agc | 75% | -79.4 | -68.7 / 0.14 | -46.7 / 0.60 | 0.08 | 0.18 |
| android-2 | raw | 99% | -44.7 | -30.6 / 0.53 | -45.8 / 0.40 | 0.53 | 0.22 |
| android-2 | ec | 99% | -51.3 | -30.7 / 0.54 | -46.5 / 0.50 | 0.54 | 0.22 |
| android-2 | voice-raw | 100% | -48.7 | -22.6 / 0.57 | -42.1 / 0.55 | 0.58 | 0.32 |
| android-2 | voice-ec | 99% | -48.8 | -46.5 / 0.25 | -44.0 / 0.47 | 0.19 | 0.51 |
| android-2 | voice-ec-ns-agc | 83% | -78.2 | -67.8 / 0.15 | -47.3 / 0.54 | 0.15 | 0.40 |
| web-1 | raw | 99% | -52.6 | -32.5 / 0.73 | -48.3 / 0.41 | 0.71 | 0.28 |
| web-1 | ec | 99% | -53.0 | -56.0 / 0.05 | -49.2 / 0.42 | 0.17 | 0.33 |
| web-1 | ec-ns-agc | 98% | -56.2 | -59.2 / 0.06 | -37.7 / 0.52 | 0.22 | 0.43 |
| web-2 | raw | 99% | -51.9 | -52.0 / 0.06 | -41.7 / 0.54 | 0.23 | 0.54 |
| web-2 | ec | 99% (mic late 8930 ms) | — | -43.0 / 0.00 | -42.1 / 0.55 | 0.22 | 0.55 |
| web-2 | ec-ns-agc | 98% (mic late 12886 ms) | — | -28.8 / 0.00 | -28.8 / 0.57 | 0.24 | 0.51 |
| web-3 | raw | 99% | -52.7 | -32.6 / 0.73 | -41.6 / 0.53 | 0.70 | 0.27 |
| web-3 | ec | 99% | -53.0 | -55.3 / 0.08 | -42.1 / 0.54 | 0.22 | 0.51 |
| web-3 | ec-ns-agc | 99% | -55.2 | -57.2 / 0.11 | -26.8 / 0.56 | 0.24 | 0.50 |

観測した事実:

- **macOS（公開版のまま）**: `macos-try1` と `macos-patch-none`（写した package で修正を切ったもの）のどちらも、`echoCancel` の行は
  0 でないサンプルが 0 個。`macos-patch-none` のログでは、voice processing を有効にした入力は 9 チャンネル・48 kHz で、
  tap の peak は 0.005〜0.055 だった。`mono` を入れた後のログでは 9 チャンネルの peak がすべて同じ値だった
- **macOS（`mono`）**: `ec` で 0 でないサンプルが 53〜56% になる。無音の間は voice processing が 0 を出す（ゲート）と考えられる。
  人の声だけの区間の音量は raw より 6〜9 dB 大きい（voice processing の中の音量調整と推定。`autoGain` を切った `ec` でも上がる）
- **iOS**: 前の lab（9/26、iPadOS 26.6.2、チャープ）では raw でも回り込みが出なかったが、今回は raw で相関 0.61〜0.65 の回り込みがあった。
  違いは、信号（声）、`allowBluetooth` を外したこと、OS の版。どれが効いたかは切り分けていない
- **Android**: `voice-raw` は、相手の声の音量が raw より 8 dB 大きい（通話用の経路の音量・増幅と推定）が、相関は下がらない。
  `voice-ec-ns-agc` は無音時が -78〜-79 dBFS で、無音の間をほぼ 0 にしている（0 でないサンプル 75〜83%）
- **Web**: `ec-ns-agc` は人の声が raw より 10〜15 dB 大きい（`autoGainControl`）
- **web-2 は失敗**: 3 枠とも `player.play` が 30 秒で返らず（`TimeoutException`）、相手の声が流れなかった。raw の相関が 0.06 で、
  `ec`・`ec-ns-agc` はマイクの開始も 9〜13 秒遅れた。Chrome を閉じて流し直した web-3 は web-1 と同じ結果。原因は調べていない
- **macos-patch-mono の raw** は、起動直後の最初の `startStream` が 11 秒遅れて計測になっていない。この後に「マイクの慣らし」を足した
  （`macos-mono-*`、`ios-*`、`android-*`、`web-*` は慣らしあり。`macos-try1` も最初の枠が 3 秒遅れている）

## 解釈

- macOS の無音は、`AVAudioConverter` が 9 → 1 チャンネルの変換で 0 を出すことによる、と考えられます。変換器のチャンネルの対応
  （channel map）が決まらない組み合わせだと推定していますが、`AVAudioConverter` の中は調べていません。
  `record_macos` を直す（1 チャンネル目を取る、または変換器に channel map を与える）と、macOS でも `echoCancel` が使えます
- Android は、`echoCancel` が付ける `AcousticEchoCanceler` が、通話用の経路の録音と再生でだけ働く、と読めます（Pixel Fold の前の lab と同じ）。
  `record` 側の設定だけでなく、**再生する側も通話用（`usageType: voiceCommunication`）にする必要**があります
- どのプラットフォームでも、OS（ブラウザ）のエコー除去が参照にしているのは、同じアプリ（タブ）が流した音です。
  今回、相手の声は `audioplayers` で流しました。別のプレーヤー（TTS など）で流した音も参照に入るかは確かめていません

## Requirements and run

```sh
mise run          # 信号を用意し、analyze と Web の build
mise run prepare  # 信号だけ（tests/assets から far.wav・near.wav を作る）
```

アプリを各プラットフォームで build・install した後（`flutter build macos|ios|apk|web --release`、iOS は `xcrun devicectl device install app`、
Android は `adb install`）、`tools/run.py` で 1 回分を流します。最初の 1 回はマイクの許可のダイアログに答える必要があります。

```sh
python3 tools/run.py --dut macos --helper android --variants raw,ec,ec-ns-agc --mac-patch mono --label macos-mono-1
IOS_DEVICE=<UDID> python3 tools/run.py --dut ios --helper mac --label ios-1 --lead 30
python3 tools/run.py --dut android --helper mac --variants raw,ec,voice-raw,voice-ec,voice-ec-ns-agc --label android-2
python3 tools/run.py --dut web --helper android --label web-1
python3 tools/summarize.py results/*.json
```

- 結果は `results/<label>.json`。録音そのもの（部屋の音）は端末の一時フォルダの `echo_recordings/` に残し、git には入れていない
- Android は `adb`、iOS は `xcrun devicectl` を使う。Android の helper はこのアプリを helper 役で起動する

## 未確認の事項と制約

- 各条件 1〜3 回。部屋・端末の位置・音量に左右される。iPad の音量は記録していない
- 相関と音量は包絡で見たもので、人の声の明瞭さ（欠け・ひずみ）を人が聞いて確かめてはいない
- 人の声は別の端末のスピーカーで代用した。本物の人の声・距離では測っていない
- macOS の修正は `record_macos` の 1 か所を lab の中で直したもの。上流へは llfbandit/record#633 で、`main`（`record_darwin`）への修正（`AVAudioConverter` の channel map）として出した（`upstream/README.md`）。ほかのマイク（外付け・Bluetooth）、
  ほかの Mac では試していない。iOS の `record_ios` は同じ作り（`setVoiceProcessingEnabled`）だが、iPad では 0 にならなかった
- Android は Pixel 6 だけ。端末によっては `AcousticEchoCanceler` が無い・効き方が違う
- Web は macOS の Chrome だけ。Safari・Firefox、ほかの OS の Chrome は試していない
- 再生に `audioplayers` 以外（OS の TTS など）を使ったとき、エコー除去の参照に入るかは確かめていない
- 長時間の連続、バックグラウンド、ほかのアプリとのマイクの取り合いは試していない
