# Always-on camera and microphone in Flutter with record and camera, and what echoCancel really does

音声対話 AI の「目と耳」として、カメラとマイクをアプリが開いている間ずっと動かし、映像フレームと PCM を Dart で
処理できるかを確かめます。WebRTC は使わず、`record`（マイク）と `camera` / `camera_desktop`（カメラ）を使います。
あわせて、スピーカーから流した音がマイクへどれだけ回り込むかを、`record` の `echoCancel` などの設定ごとに測りました。

前提となる lab:
- [Flutter realtime media pipeline](../../25/flutter-realtime-media-pipeline/README.md)
- [flutter_webrtc media taps](../../25/flutter-webrtc-media-taps/README.md)（flutter_webrtc 経由だと、送信先の無い間は
  macOS・iOS・Windows でマイクが取れなかった）

## Purpose

1. `record` の PCM ストリームと `camera` の画像ストリームが、5 つのプラットフォーム（Web / macOS / iOS / Android / Windows）で
   途切れずに Dart へ届くか（頻度、形式、最大の途切れ）
2. フレームを一定間隔（200 ms）で間引き、Dart で 320 幅の RGB に変換するといくらかかるか
3. スピーカーからテスト音を流しながら録音したとき、`echoCancel` / `noiseSuppress` / `autoGain` の設定で、回り込みがどう変わるか

## Answer

- **カメラとマイクは、5 つのプラットフォームすべてで途切れずに届きました。** マイクは 16 kHz・モノラル・16 bit の PCM が
  1 秒に 10〜25 回（最大の途切れ 49〜117 ms）、カメラは 1280×720（iPad は縦長の 720×1280）が 20〜30 fps です。
  WebRTC と違い、送信先が無くてもマイクが取れます
- **Dart での RGB 化（320 幅、最近傍）は 1 回 0.2〜3.2 ms**（ネイティブ）、Web は 7.3 ms でした
- **`echoCancel` の効き方は、プラットフォームごとにまったく違いました。**

  | プラットフォーム | 結果 |
  | --- | --- |
  | macOS | `echoCancel` を有効にすると、**マイクの音が全サンプル 0（完全な無音）になる**。エコー除去としては使えない |
  | Android | `echoCancel` だけでは効かない。**録音の入力を `voiceCommunication`、音声モードを `inCommunication`、再生を通話用に揃えると効く**（回り込み -20.6 → -58.7 dBFS、相関 0.89 → 0.10） |
  | Windows | 効かない（`record` の Windows 実装はこの設定を読むが使っていない） |
  | iPad | **設定に関係なく回り込みが検出されなかった**（音は鳴っていた）。原因は未特定 |
  | Web | headless Chrome の fake のマイクではスピーカーの音を拾えないので未計測 |

- 会話 AI と同じ端末のスピーカーで話すなら、エコー除去は `record` の設定だけには頼れません。Android は通話用の音声経路に揃える
  必要があり、macOS と Windows は別の手段（OS の音声処理、自前のエコー除去、ヘッドホン）が要ります

## Setup

- `app/`: Flutter アプリ。Flutter 3.47.2、`record` 7.1.1、`camera` 0.12.1、`camera_desktop` 2.0.0（macOS / Windows の
  `camera` 実装）、`audioplayers` 6.8.1（テスト音の再生）
- マイク: `record.startStream(RecordConfig(encoder: pcm16bits, sampleRate: 16000, numChannels: 1, ...))`
- カメラ: Android・iOS は `camera`（Android は YUV420、iOS は BGRA）、macOS・Windows は `camera_desktop`（BGRA）、
  Web は `camera` の Web 実装に画像ストリームが無いので、`getUserMedia` → `MediaStreamTrackProcessor` →
  `VideoFrame.copyTo(RGBA)` を自前で呼ぶ（`lib/camera_probe_web.dart`）
- 解像度の指定は `ResolutionPreset.high`（Web は 1280×720 を要求）。フレームは届くたびに数え、200 ms に 1 回だけ Dart で
  320 幅の RGB（最近傍）に変換する

### echo テスト

1. 設定を変えてマイクを開き、1.5 秒待つ
2. 2 秒の無音区間の音量を測る（基準）
3. 300 Hz → 3.4 kHz のチャープ（250 ms、50 ms 間隔）を 4 秒、スピーカーから流しながら録音する。定常の音はノイズ抑制が
   消してしまうので、エコー除去の効果と区別するために、音声に近い変化する音にした
4. 再生中の音量（dBFS）と、流した信号の包絡との相関（0〜600 ms の遅延を探索）を比べる。**相関が回り込みの指標**で、
   1 に近いほど流した音がそのまま入っている

設定は `raw`（すべて無効）、`ec`（`echoCancel`）、`ec-ns-agc`（3 つとも有効）。Android だけ `voice-ec-ns-agc`
（`AndroidAudioSource.voiceCommunication`、`AudioManagerMode.modeInCommunication`、再生は `AndroidUsageType.voiceCommunication`）を足した。
端末の音量はそのまま（変えていない）。

`echoCancel` の実装（パッケージのソースで確認）:

| プラットフォーム | `record` の実装 |
| --- | --- |
| Android | `AcousticEchoCanceler` / `NoiseSuppressor` / `AutomaticGainControl` の effect を録音セッションに付ける |
| iOS / macOS | `AVAudioEngine.inputNode.setVoiceProcessingEnabled(echoCancel)`（Apple の voice processing） |
| Web | getUserMedia の `echoCancellation` / `noiseSuppression` / `autoGainControl` |
| Windows | 引数として受け取るが、どこにも使っていない（既定の communications 用の録音デバイスを選ぶだけ） |

## Results

機材: macOS は MacBook Pro M1 Max（内蔵カメラ・マイク・スピーカー）、iOS は iPad Air 第 4 世代（iPadOS 26.6.2）、
Android は Pixel Fold（Android 17）、Windows は Windows 11 のデスクトップ PC、Web は Chrome 153 headless（fake のカメラ・マイク）。
すべて release ビルド、各 1 回。数値は `results/*.json`。

### カメラとマイク（20 秒）

| プラットフォーム | マイク（届いた量 / 1 秒あたりの回数 / 最大の途切れ） | カメラ（fps / 解像度 / 形式） | RGB 化 p50 / p95 (ms) |
| --- | --- | --- | --- |
| Web | 16.0 k/s / 21.6 回 / 56 ms | 20.0 fps / 1280×720 / NV12 | 7.3 / 10.5 |
| macOS | 16.1 k/s / 10.1 回 / 111 ms | 29.8 fps / 1280×720 / BGRA | 0.48 / 0.82 |
| iOS | 16.1 k/s / 10.0 回 / 117 ms | 30.0 fps / 720×1280 / BGRA | 3.2 / 3.8 |
| Android | 16.0 k/s / 25.1 回 / 68 ms | 30.0 fps / 1280×720 / YUV420（3 面） | 0.98 / 1.4 |
| Windows | 16.0 k/s / 21.4 回 / 49 ms | 30.3 fps / 1280×720 / BGRA | 0.20 / 0.33 |

- 1 回あたりのマイクの量は、macOS・iOS が 2,708〜3,200 バイト（約 100 ms）、Android が 1,280 バイト（40 ms）、
  Windows が 898〜1,600 バイト、Web が約 1,487 バイトでした。奇数バイトで切れた回は 0 でした
- 変換は 200 ms 間隔の指定に対して、1 秒に 4.4〜4.7 回行われました
- Windows の既定のカメラとして選ばれたのは、USB カメラではなく **Windows の「スマホ連携」の仮想カメラ（Pixel Fold）**でした。
  このアプリは最初に見つかったカメラ（前面が無ければ先頭）を使います
- iPad の RGB 化が他より遅いのは、縦長の 720×1280 から 320 幅にするため、出力の行数が多い（320×569）ためです
- Web の RGB 化には `copyTo(RGBA)`（ブラウザ内の変換とコピー、1280×720×4 バイト）が含まれます

### echo テスト

| プラットフォーム | 設定 | 無音時 (dBFS) | 再生中 (dBFS) | 相関 | 遅延 (ms) |
| --- | --- | --- | --- | --- | --- |
| macOS | raw | -44.1 | -26.7 | **0.80** | 277 |
| macOS | ec | 無音（全サンプル 0） | 無音 | — | — |
| macOS | ec-ns-agc | 無音（全サンプル 0） | 無音 | — | — |
| Android | raw | -33.9 | -20.6 | **0.91** | 410 |
| Android | ec | -43.8 | -20.7 | **0.89** | 380 |
| Android | ec-ns-agc | -42.5 | -20.7 | **0.89** | 392 |
| Android | voice-ec-ns-agc | -30.4 | **-58.7** | **0.10** | 270 |
| Windows | raw | -42.2 | -29.4 | 0.45 | 261 |
| Windows | ec | -52.3 | -28.6 | 0.37 | 242 |
| Windows | ec-ns-agc | -34.6 | -22.4 | 0.52 | 220 |
| iOS | raw | -36.0 | -35.7 | 0.09 | 93 |
| iOS | ec | -46.0 | -40.3 | 0.10 | 207 |
| iOS | ec-ns-agc | -46.2 | -36.5 | 0.12 | 178 |

観測した事実:

- **macOS で `echoCancel` を有効にすると、`record` は 16 kHz のペースでサンプルを渡し続けるものの、中身がすべて 0 でした**
  （2 回の試行で同じ）。voice processing を有効にした入力ノードが無音を返していると考えられますが、原因は調べていません
- **Android は、`echoCancel` を有効にしても回り込みが変わりませんでした**（相関 0.89〜0.91）。通話用の入力・モード・再生に揃えた
  ときだけ、再生中の音量が -58.7 dBFS まで下がり、相関も 0.10 になりました。このとき無音時の音量は -30.4 dBFS に上がっており
  （自動音量調整による持ち上げと推定）、通話向けの処理が掛かった音になります
- **Windows は、設定を変えても相関が 0.37〜0.52 のままでした。** ソースどおり、エコー除去は効いていません
- **iPad は、どの設定でも再生中の音量が無音時とほぼ同じで、相関も 0.09〜0.12 でした。** テスト音はスピーカーから聞こえていた
  （利用者が確認）。`audioplayers` の音声セッションの設定を外した場合（`results/ios-echo-playerctx-none.json`）も同じでした。
  iPadOS 側の処理で消えているのか、マイクの位置や経路の問題なのかは切り分けていません
- 無音時の音量が設定ごとに変わるのは、ノイズ抑制と自動音量調整が部屋の雑音を上げ下げするためです

## Requirements and run

```sh
mise run                # analyze と Web の build
mise run web-autorun    # headless Chrome でカメラとマイク（echo は skip）→ results/web.json
mise run macos-autorun  # macOS でカメラとマイク、echo テスト（スピーカーからテスト音が鳴る）→ results/macos.json
```

ほかのプラットフォームは、`scenario`（`all` / `senses` / `echo`）・`seconds`・`interval`（ms）・`preset`・`playerctx`・`exit` を
次の方法で渡します。結果は `SENSES_RESULT {json}` の 1 行と、一時ディレクトリの `senses_result.json` に出ます。

| プラットフォーム | 渡し方 | 結果の受け取り方 |
| --- | --- | --- |
| Windows / macOS | 環境変数 `SENSES_SCENARIO` など | Windows は `%TEMP%\senses_result.json`（GUI アプリなので対話セッションで起動する） |
| iOS | `devicectl device copy to` でアプリの `tmp/senses_config.json` に置く | `devicectl device copy from` で `tmp/senses_result.json` |
| Android | `adb shell am start -n com.kiarina.labs.senses_app/.MainActivity --es scenario all ...`。カメラとマイクは `pm grant` で付与 | logcat の `SENSES_PART i/n` |

## 未確認の事項と制約

- 各条件 1 回ずつの計測です。echo テストは部屋の雑音と端末の音量に左右されます（音量は変えていない）
- 会話の声（近端の話者）がエコー除去でどれだけ残るかは測っていません。回り込みの量だけです
- iPad で回り込みが出なかった理由、macOS で `echoCancel` が無音になる理由は未特定です
- Web の echo テストは、実際のマイクとスピーカーのある Chrome で測っていません（ブラウザのエコー除去が効く見込み）
- 長時間（数十分以上）の連続動作、バックグラウンド化、他のアプリとのマイクの取り合いは試していません
- iPhone、Android の他の機種、Windows の USB カメラは試していません
