# LTX-2 dialogue video generation

LTX-2 distilledで、二人の短い会話を含む動画を生成できるか検証します。

## Purpose

明らかにしたい問いは次のとおりです。

- `generate_audio=true`だけで、指定した一往復の台詞を含むMP4を生成できるか
- 既知の二話者音声をA2V入力した場合、会話場面と音声を含むMP4を生成できるか
- 話者交替と人物の口元の動きが概ね対応するか

評価基準は、次の4項目を事前に定めました。

1. MP4に映像と音声の両streamが存在する
2. 女性、男性の順で二つの台詞が聞き取れる
3. 二人が画面に現れ、話者交替らしい口元の変化がある
4. job metadataと実ファイルの音声有無が一致する

## Conditions

共通の生成条件は次のとおりです。

| Item | Value |
|---|---|
| API | kiapi LTX-2 API 0.5.2、kiapi-proxy経由 |
| Model | `distilled`、`prince-canuma/LTX-2-distilled` |
| mlx-video | 0.0.1、commit `87db56a51758fefb748a359b90a5283bb8ba4837` |
| Size | 512 x 512 |
| Frames | 161 |
| Frame rate | 24 fps |
| Duration | 6.708333秒 |
| Trials | T2V+AudioとA2Vを各1回 |

推論はMac Studio M4 Max、128 GB、macOS 26.5.2で実行しました。kiapiは
commit `53b4abf894caa44be2a1b6256eb4030a94172259`、Python 3.12.11、
MLX 0.31.2を使用しました。LTX-2は約101 GBのmodel assetを使用し、呼び出しごとに
約40 GBの一時memory budgetを確保するtransient modelです。

A2Vの駆動音声はMacBook Pro M1 Max、64 GB、macOS 26.5.2の`say`で作成し、
FFmpeg 8.1.2で連結、変換しました。

### T2V+Audio

seedは`7302026`、`generate_audio=true`とし、次のpromptを使用しました。

```text
A cozy independent bookstore, medium two-shot of a young adult woman in a green
sweater and a young adult man in a blue shirt facing each other. Natural
cinematic live-action, static camera. The woman clearly asks in English, Did you
bring the map? Brief pause. The man clearly replies in English, Yes, it is right
here. Both speak one at a time with distinct natural voices and accurate lip
movement. Only quiet bookstore room tone behind the clear dialogue. Clean frame
without captions or on-screen text.
```

### A2V

macOS `say`で既知の二話者音声を作りました。

| Order | Voice | Rate | Text |
|---:|---|---:|---|
| 1 | Samantha | 185 | `Did you bring the map?` |
| 2 | Daniel | 185 | `Yes, it is right here.` |

1発話目の後ろへ0.5秒を追加して連結し、48 kHz、mono、PCM 16-bit、6.708333秒の
WAVにしました。seedは`7302027`で、次のpromptを使用しました。

```text
A cozy independent bookstore, medium two-shot of a young adult woman in a green
sweater and a young adult man in a blue shirt facing each other. Natural
cinematic live-action, static camera, clean frame. The woman speaks first, then
after a brief pause the man replies. Their natural mouth movements follow the
supplied dialogue audio, with clear alternating speaker turns and attentive
facial reactions.
```

## Run

公開済みの最終MP4を取得し、SHA-256、duration、codec、解像度、frame rate、音声形式を
検証します。FFprobeが必要です。

```sh
mise -C 2026/07/30/ltx2-dialogue-video run
```

Macで会話音声の作成から再生成まで行う場合は、kiapi APIへ到達できる状態で次を実行します。

```sh
mise -C 2026/07/30/ltx2-dialogue-video run generate
```

APIのURLは`KIAPI_BASE_URL`で変更できます。生成物とjob JSONはGit管理外の`output/`へ
保存します。

## Observed results

| Trial | Generation | Visual result | Job `has_audio` | Actual MP4 audio | Criteria |
|---|---:|---|---:|---:|---|
| T2V+Audio | 90.38秒 | 書店の男女。女性に発話らしい口元の動き。意味不明な字幕あり | `true` | なし | 1、2、4を満たさない |
| A2V | 94.11秒 | 書店の男女。異なる時刻に両者の口形が変化 | `true` | なし | 1、2、4を満たさない |

両jobは`status=succeeded`で、modeもそれぞれ`T2V+Audio`、`A2V`でした。しかし
FFprobeで確認したraw MP4はいずれもH.264映像streamが1本だけで、音声streamを
含みませんでした。同じファイルをMac Studioのkiapiへ直接接続して取得しても結果は
同じだったため、kiapi-proxyによる欠落ではありません。

T2V+Audioの連続frameでは女性の口元が変化しましたが、男性は主に背面から描かれました。
指定ではclean frameを求めたものの、`Freed, Gu Dnd it? Ge's hoy??`のような意味不明な
字幕が現れました。LTX-2 distilledはnegative guidanceを持たないため、抑制的な記述で
字幕を確実に避けられるとは限りません。

A2Vでは二人が同じ画面に現れ、女性と男性の口形が異なる時刻に変化しました。静止frameの
比較では交互発話らしい変化を観測しましたが、音素単位のlip syncを測定していないため、
正確な同期は確認済みとはしません。

詳細な条件、hash、job結果の要約は[`results/summary.json`](results/summary.json)に
記録しています。

## Workaround artifact

A2Vに渡した既知のWAVをraw A2V映像へFFmpegでmuxし、自己完結した会話動画を作成しました。

```text
tests/assets/mp4/ltx2_dialogue_512x512_24fps_7s_355kb.mp4
```

| Property | Value |
|---|---|
| SHA-256 | `20e1c86950574d95ad72ed2d324407aa7e48d6013a5d556cdd9517fb71e412ff` |
| Duration | 6.708008秒 |
| Video | H.264、512 x 512、24 fps |
| Audio | AAC、48 kHz、mono |

このMP4の音声はLTX-2が合成した音声ではなく、A2Vの駆動入力と同じ既知音声です。
したがって台詞の内容と順序は保持されますが、nativeなT2V+Audio成功例ではありません。

## Interpretation

### Observed facts

- T2V+AudioとA2Vの両方で、会話場面らしい二人の映像を生成できた
- A2Vでは、入力音声の話者交替と整合しそうな口形変化が見られた
- 両raw MP4に音声streamはなかった
- 両jobは実ファイルと矛盾する`has_audio=true`を返した
- A2Vの入力音声を生成後にmuxすれば、会話音声を含むMP4になった

### Interpretation and inference

LTX-2は会話を想定した映像や、会話音声に駆動された人物動作を生成できます。ただし、今回の
kiapi 0.5.2と固定mlx-video commitでは、LTX-2 APIだけから音声付きMP4を得られませんでした。
現状で会話を含む成果物を作るには、A2V入力音声を生成後にmuxする工程が必要です。

kiapiの実装は`audio.wav`の存在から`has_audio`を決めた後、mlx-videoがMP4へmux済みと仮定して
WAVを削除します。実ファイルには音声がなかったため、mux完了をstream検査で確認するか、
kiapi側で明示的にmuxする必要があると推測します。これはコードと出力からの推測であり、
mlx-video内部の全経路を追跡した結論ではありません。

## Failed attempts and reproducibility notes

- 最初はkiapi-proxyが動くMacBook Pro上でLTX-2をactivateしようとし、約23 GBと表示された
  downloadを途中で中止しました。実際の推論serviceはMac Studioで動いており、そちらには
  約101 GBのmodel assetがすでに存在していました。
- Mac Studioでは`mlx-video-ltx2` Python packageだけが不足していました。実行中jobがないことを
  確認し、serviceを停止して`uv run kiapi activate --repo mlx-video-ltx2`を実行後、serviceを
  再起動しました。
- `say`の最初の試行では、AIFFとlittle-endian PCM指定の組み合わせが不正で失敗しました。
  WAVE、`LEI16`へ変更して解決しました。
- raw MP4から音声を抽出するFFmpeg処理は、音声streamが存在しないため失敗しました。

## Limitations

- 各modeを1 seed、1 prompt、英語の短い二話者会話だけで評価した
- 人物の口元はframeを定性的に確認しただけで、lip syncを定量評価していない
- T2V+Audioが生成した一時WAVはkiapiが削除するため、音声内容を評価できなかった
- 最終MP4の台詞は既知のA2V入力であり、LTX-2によるspeech synthesis性能を示さない
- 512 x 512、約6.7秒だけを評価し、長時間、高解像度、日本語会話を確認していない
- 使用modelの派生repositoryには独自のlicense表記がなく、派生元のLTX-2 Community
  License Agreementへの準拠を前提としている。再配布や用途ごとに条件確認が必要

## References

- [kiapi LTX-2 capability](https://github.com/kiarina/kiapi/tree/main/packages/kiapi/src/kiapi/capabilities/ltx2)
- [mlx-video](https://github.com/Blaizzy/mlx-video)
- [LTX-2 distilled model](https://huggingface.co/prince-canuma/LTX-2-distilled)
