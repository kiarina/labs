# OS text-to-speech as PCM in Flutter (macOS, iOS, Windows, Android)

OS の音声合成（TTS）の声を、鳴らさずに 16 bit の PCM で Dart へ受け取る Flutter の plugin `tts_pcm` を作り、
macOS・iOS・Windows・Android の実機で、受け取れる形・速さ・中身を確かめました。

アプリが TTS を自分で鳴らすと、何をいつ鳴らしたかをアプリが正確に知れます。それを使って、
マイクのエコー除去に鳴らした音を参照として渡したり、マイクで聞いた自分の声に印を付けたりしたい
（[record の echoCancel の lab](../flutter-record-echo-cancel/README.md) の続き）。
既存の [flutter_tts](https://pub.dev/packages/flutter_tts) 4.2.5 は、Windows では合成した音を自分で鳴らすだけで PCM を出さず、
macOS ではファイル（書類フォルダの決まった場所）にしか書けないので、自前で作りました（ソースを読んで確認）。

## 問い

1. 各 OS で、合成した声を鳴らさずに PCM で受け取れるか。どんな形式で、少しずつ（ストリーム）届くか、まとめて届くか
2. 最初の音が届くまで・全部届くまでの時間は
3. 日本語の声はいくつあり、中身は正しいか（OS の音声認識で文字に戻して確かめる）
4. 途中で止められるか。2 つ同時に頼めるか

## Findings

| | macOS | iOS（iPad Air 4） | Windows | Android（Pixel 6） |
| --- | --- | --- | --- | --- |
| 使う API | `AVSpeechSynthesizer.write` | 同じ | `Windows.Media.SpeechSynthesis`（`SynthesizeTextToStreamAsync`） | `TextToSpeech.synthesizeToFile` ＋ `onAudioAvailable` |
| 届き方 | 小さなかたまり（256 サンプルほど）で届くが、Kyoko は全部できてから一気に届く | 同じ | WAV 1 本でまとめて | 合成しながら少しずつ |
| 形式（既定の日本語の声） | float32・22,050 Hz・モノラル | 同じ | 16 bit・16,000 Hz・モノラル | 16 bit・24,000 Hz・モノラル（network の声は 48,000 Hz） |
| 最初の音まで（2 回目、3 秒の文） | 747 ms（Kyoko） | 808 ms | 32 ms（全部） | 36 ms |
| 全部まで（11〜13 秒の文） | 1,006 ms | 985 ms | 57 ms | 127 ms |
| 日本語の声 | 9（Kyoko と、Eddy などの新しい声 8） | 10（macOS の 9 ＋ O-ren） | 3（Ayumi・Haruka・Ichiro） | 9（local 5・network 4） |
| 文字に戻した CER（日本語の短い文 / 長い文） | 0 / 3.6% | 0 / 3.6% | 0 / 3.6% | 0 / 5.4% |
| 途中で止める | 止まる（遅れて届くかたまり 0） | 止まる（0） | 止まる（結果を捨てる） | 止まるが、止めた後に 15 かたまり届いた（Dart 側で捨てる） |
| 2 つ同時 | どちらも完了 | どちらも完了 | どちらも完了 | どちらも完了（エンジンは 1 つで、順番に処理される） |

- **4 つの OS とも、鳴らさずに PCM で受け取れました。** どの OS も、同じ文なら毎回同じ長さの音になりました（2 回とも同じ値）
- **Apple の Kyoko は遅い。** 3 秒の文で約 0.75〜0.8 秒、11 秒の文で約 1 秒かかり、最初のかたまりは全部できる 60〜160 ms 前に届く。
  Eddy・Flo などの新しい声は、最初の音まで 13〜20 ms（Eddy は 110〜153 ms）、全部まで 60〜80 ms で、形式は 16,000 Hz
- **Windows は 1 回の呼び出しで全部返る**が、とても速い（13 秒の文で 57 ms）。この PC には英語の声が入っておらず、
  `en-US` を頼むと既定の日本語の声（Ayumi）で英語を読み、文字に戻すと正しく英語になった
- **Android は本当に少しずつ届く**（最初の音まで 28〜39 ms）。各セッションの最初の 1 回だけ 243〜699 ms かかる（エンジンの起動）。
  network の声は 48,000 Hz で、最初の音まで 313〜596 ms
- 文字に戻した結果の誤りは、ほとんど「合掌造り」→「合唱作り」（読みが同じ。認識の側の誤り）と、Android の「白川郷」→「白川号」。
  Apple の Rocko だけ「天気」→「連中」（CER 13%）
- 声の一覧を取るのにかかった時間: macOS 100 ms（180 声）、iOS 240 ms（193 声）、Windows 32 ms（3 声）、Android 886 ms（474 声）

## 作ったもの

`packages/tts_pcm`（この lab の中の plugin。続きは [kiarina/tts_pcm](https://github.com/kiarina/tts_pcm) に移し、声の一覧の形をそろえた。この lab とは同期しない）:

```dart
final voices = await TtsPcm.instance.voices(language: 'ja');
await for (final chunk in TtsPcm.instance.synthesize('こんにちは', language: 'ja-JP')) {
  chunk.samples;    // Int16List（16 bit・モノラル）
  chunk.sampleRate; // 22050 など。OS の声のまま（変換しない）
}
// 止めるときは listen の subscription を cancel する
```

- 鳴らす・止めるは持たない。呼び出し側がスピーカーを持つ
- 形式は 16 bit・モノラルにそろえ、サンプリングレートは OS の声のまま返す（`nativeFormat` に元の形式を書く）
- `rate` は OS の普通の速さを 1.0 とした倍率
- macOS・iOS は 1 つの Swift のソース（`sharedDarwinSource`）。頼みごとに `AVSpeechSynthesizer` を 1 つ作る（止めても他に影響しない）
- Windows は別のスレッドで合成し、結果を窓のメッセージで platform のスレッドへ戻す（チャンネルは platform のスレッドでしか使えない）。
  C++/WinRT は Windows SDK のものを使い（`windowsapp` をリンク）、NuGet は要らない
- Android は `synthesizeToFile` の一時ファイルに書かせ、`onAudioAvailable` で届いた PCM を送り、終わったらファイルを消す。
  エンジンは 1 つなので、声・言語・速さは頼んだ時点でエンジンに設定し、止めるとエンジンの処理を全部止める。
  API 30 以上を対象にするアプリは TTS のサービスを見るために `<queries>` が要る（plugin の manifest に入れた）
- Web は対象外。ブラウザの `speechSynthesis` には音のデータを取り出す口が無い

## 方法

計測アプリ（`app/`）は、起動の設定を受け取ると次を順に行い、結果を JSON にする。

1. 声の一覧（全部と、日本語の声）
2. 3 つの文（日本語の短い文 17 文字・長い文 56 文字・英語の短い文）を、言語の既定の声で 2 回ずつ合成。
   1 回目はエンジンの起動を含む。2 回目の音を、OS の音声認識（pub.dev の [pcm_asr](https://pub.dev/packages/pcm_asr) 0.1.2）で
   16 kHz に直して文字に戻し、元の文との CER（句読点と空白を除いた文字の編集距離 ÷ 元の文字数）を出す
3. 日本語の声それぞれで短い文を合成して、文字に戻す
4. 長い文を頼み、最初のかたまりが届いたら止める。その後 2 秒に届いたかたまりを数え、続けて次の合成が通るか見る
5. 日本語と英語の短い文を同時に頼む

測った時間は、Dart で `synthesize` を呼んでから最初のかたまり・最後のかたまりが届くまで（チャンネルの往復を含む）。
合成した音は端末の一時フォルダの `tts_wavs/` に WAV で残す（git には入れない）。

### 環境

- Flutter 3.47.2。すべて release ビルド。各 OS 1 回（文ごとに 2 回）
- macOS: MacBook Pro M1 Max、macOS 27.0.1
- iOS: iPad Air 第 4 世代、iPadOS 27.0.1
- Windows: Core i9-12900K・64 GB、Windows 11 Home Insider Preview（build 26220）。文字起こしは pcm_asr の whisper.cpp
  （large-v3-turbo q5_0、Vulkan）。モデルは前に取ったものを `TTS_ASR_MODEL_DIR` で指した
- Android: Pixel 6、Android 17、Google の音声合成（`com.google.android.tts` versionCode 210683481）

## Results

数値は `results/*.json`。`python3 tools/summary.py` で読みやすく出せる。

<details>
<summary>tools/summary.py の出力</summary>

```text
## macos-1: 180 voices (100 ms), ja ['Kyoko', 'Eddy', 'Flo', 'Grandma', 'Grandpa', 'Reed', 'Rocko', 'Sandy', 'Shelley'], en 41
  ja-short #0: first 1299 ms, total 1363 ms, audio 3095 ms, chunks 267, float32 22050 Hz 1 ch, lead 95 ms, peak -9.4 dBFS
  ja-short #1: first 747 ms, total 815 ms, audio 3095 ms, chunks 267, float32 22050 Hz 1 ch, lead 95 ms, peak -9.4 dBFS, CER 0.000
  ja-long #0: first 841 ms, total 1003 ms, audio 10694 ms, chunks 922, float32 22050 Hz 1 ch, lead 15 ms, peak -9.1 dBFS
  ja-long #1: first 843 ms, total 1006 ms, audio 10694 ms, chunks 922, float32 22050 Hz 1 ch, lead 15 ms, peak -9.1 dBFS, CER 0.036
  en-short #0: first 472 ms, total 532 ms, audio 3015 ms, chunks 260, float32 22050 Hz 1 ch, lead 14 ms, peak -2.7 dBFS
  en-short #1: first 437 ms, total 503 ms, audio 3015 ms, chunks 260, float32 22050 Hz 1 ch, lead 14 ms, peak -2.7 dBFS, CER 0.000
  voice Kyoko: first 732 total 799 audio 3095 float32 22050 Hz CER 0.0
  voice Eddy: first 153 total 209 audio 3321 float32 16000 Hz CER 0.0
  voice Flo / Grandma / Grandpa / Reed / Sandy / Shelley: first 19-23 total 77-81 audio 3321 float32 16000 Hz CER 0.0
  voice Rocko: first 19 total 77 audio 3321 float32 16000 Hz CER 0.133（「天気」→「連中」）
  cancel: late chunks 0, next ok 3095 ms audio
  concurrent: 3095 ms audio in 1096 ms, 3015 ms audio in 798 ms
## ios-1: 193 voices (240 ms), ja [macOS の 9 声 + 'O-ren'], en 47
  ja-short #1: first 808 ms, total 866 ms, audio 3095 ms, float32 22050 Hz, CER 0.000
  ja-long #1: first 799 ms, total 985 ms, audio 10694 ms, CER 0.036
  en-short #1: first 428 ms, total 483 ms, audio 3015 ms, CER 0.000
  voice Eddy: first 110 total 156 / Flo ほか: first 13-14 total 59-60（16000 Hz） / O-ren: first 743 total 793（22050 Hz）。CER は Rocko 0.133、ほか 0
  cancel: late chunks 0 / concurrent: 両方完了（1065 ms・769 ms）
## windows-1: 3 voices (32 ms), ja ['Microsoft Ayumi', 'Microsoft Haruka', 'Microsoft Ichiro'], en 0
  ja-short #0: first 143 ms, total 143 ms, audio 4050 ms, chunks 1, pcm16 16000 Hz 1 ch, lead 175 ms, peak -3.3 dBFS
  ja-short #1: first 32 ms, total 32 ms, audio 4050 ms, chunks 1, CER 0.000
  ja-long #1: first 57 ms, total 57 ms, audio 12880 ms, chunks 1, CER 0.036
  en-short #1: first 36 ms, total 36 ms, audio 5295 ms, chunks 1, CER 0.000（日本語の声で英語を読んだ）
  voice Ayumi: 30 ms / Haruka: 54 ms / Ichiro: 56 ms。CER すべて 0
  cancel: late chunks 0 / concurrent: 両方完了（32 ms・37 ms）
## android-1: 474 voices (886 ms), ja 9（local 5・network 4）, en 52
  ja-short #0: first 432 ms, total 600 ms, audio 2951 ms, chunks 141, int16 24000 Hz 1 ch, lead 45 ms, peak -3.1 dBFS
  ja-short #1: first 36 ms, total 70 ms, audio 2951 ms, chunks 141, CER 0.000
  ja-long #0: first 243 ms, total 764 ms / #1: first 28 ms, total 127 ms, audio 11436 ms, chunks 544, CER 0.054
  en-short #0: first 699 ms, total 899 ms / #1: first 39 ms, total 75 ms, audio 2988 ms, CER 0.000
  voice local（24000 Hz）: first 36-129 total 94-291 / network（48000 Hz）: first 313-596 total 438-717。CER すべて 0
  cancel: late chunks 15, next ok
  concurrent: 両方完了（68 ms・551 ms）
```

</details>

## 解釈

- アプリが自分で鳴らす前提なら、**どの OS でも、話し始めの遅れはほぼ合成の時間で決まります。** Windows・Android・Apple の新しい声は
  数十 ms で、会話の邪魔にならない。Apple の既定の声（日本語の Kyoko、英語の既定の声）は 1 文で 0.4〜0.8 秒かかるので、長い返事は文ごとに区切って頼み、
  前の文を鳴らしている間に次を合成するのがよさそうです
- Windows はまとめて返るので、Windows でも文ごとに区切れば、先頭の遅れは短く保てます
- Android の「止めた後に届くかたまり」は、`stop()` の前にエンジンが出していたもの（メインスレッドへ送る途中）と考えています。
  呼び出し側で捨てれば問題ありません

## Requirements and run

```sh
mise run              # analyze（plugin と app）
mise run android 1    # Android の実機に入れて流し、results/android-1.json（ADB・ANDROID_SERIAL で端末を選ぶ）
```

- macOS: `flutter build macos --release` の後、`open -W -n --env 'TTS_CONFIG={"exit":true}' --stdout build/macos.log app/build/macos/Build/Products/Release/tts_app.app`。
  結果は log の `TTS_PART i/n` の行をつなげたもの
- iOS: `flutter build ios --release` → `xcrun devicectl device install app` → `{"exit":true}` をアプリの `tmp/tts_config.json` に
  `devicectl device copy to` で置いて起動 → `tmp/tts_result.json` を `copy from`
- Windows: lab をビルドのディレクトリを除いてコピーし、`powershell -ExecutionPolicy Bypass -File tools\windows\run.ps1 [-ModelDir <whisper のモデルのフォルダ>] [-NoAsr]`。
  ビルドしてデスクトップのセッションで起動し（SSH のセッションからは GUI が起動できない）、`build\windows-result.json` に書く。
  pcm_asr の whisper.cpp のビルドに Vulkan SDK を使う

## 未確認の事項と制約

- 各 OS 1 回（文ごとに 2 回）。端末の負荷・温度・ほかのアプリで変わる
- 声の聞こえ方（自然さ・抑揚）は人が聞いて確かめていない。CER は中身が合っているかの目安にすぎない
- Apple の enhanced・premium の声（あとから入れる高品質の声）は入っておらず、測っていない。Kyoko も default の品質
- Windows の「ナレーターの自然な音声」は `Windows.Media.SpeechSynthesis` の一覧に出ない。この PC の 3 声だけで測った
- Android は Pixel 6 と Google の音声合成だけ。ほかのメーカーのエンジンは `onAudioAvailable` の出し方が違うかもしれない。
  network の声はネットワークにつながっていることが前提
- 長い文章（数百文字以上）、SSML、読みの指定は試していない
- 実際にスピーカーで鳴らす部分と、エコー除去への参照の渡し方は、この lab の範囲外
