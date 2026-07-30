# LTX-2 動画生成ガイド

この文書は、kiapi の LTX-2 API で短い動画、とくに二人の会話動画を生成するための
実践的な知見をまとめる。API の正確な schema は、実行時の
`/v1/video/ltx2/openapi.json` を正とする。

## 結論

台詞を正確に保持した会話動画には、先に会話音声を作り、その音声を渡す A2V を使う。
T2V+Audio は雰囲気を含む音声と映像の同時生成には使えるが、複数話者の台詞、発話順、
音声の有無を安定して制御できなかった。

良好だった条件は次のとおり。

- 10 秒程度の音声に、発話と発話の間を明確に入れる
- 場面は無地の室内など、文字、看板、印刷物が自然に存在しない場所にする
- prompt は 1 段落、200 語以内で、画面内の動作を時系列順に記述する
- 人数、左右の配置、画角、カメラ、話す人と聞く人の動作だけを具体的にする
- `no subtitles` のような禁止事項を並べず、望む画面を肯定形で記述する
- 一度に人物、動作、背景小物、カメラ移動を詰め込まない

## モードの選択

| 目的 | 推奨モード | 備考 |
|---|---|---|
| 自由な映像と環境音 | T2V+Audio | `generate_audio=true`。台詞の正確性は期待しない |
| 正確な台詞を含む会話 | A2V | 先に作った音声を `audio` に指定する |
| 構図と会話を固定 | A2V+I2V | A2V に開始画像を追加する。人物配置の安定化に有効と考えられる |
| 無音動画 | T2V または I2V | `generate_audio=false` |

公式の `A2VidPipelineTwoStage` は、入力音声の latent を固定して映像を生成し、元の
音声波形を出力へ渡す。台詞を生成モデルに再合成させないため、会話内容を保持できる。
今回の mlx-video では 48 kHz、mono の入力が 16 kHz、stereo の AAC になったため、
sample rate と channel は変わるが、台詞と発話区間は保持された。

## Prompt の組み立て

LTX-2 の公式ガイドは、主動作から書き始め、人物の動き、外見、環境、カメラ、照明、
時間変化の順で、具体的かつ時系列に記述することを推奨している。複雑な場面や指示の
詰め込みは prompt adherence を下げる。

distilled model は CFG=1 の高速モデルで、negative guidance による抑制を期待できない。
たとえば、書店を指定してから `no readable text` と加えるより、最初から無地の壁だけが
ある部屋を指定する。字幕、ロゴ、看板などの語を禁止事項として列挙すると、それらの
概念を画面へ誘発する場合があった。

会話 A2V で良好だった prompt は次のとおり。

```text
Inside a quiet room with a smooth warm beige wall, a young woman in a plain
green sweater stands on the left and a young man in a plain blue shirt stands
on the right. Only these two people are present. A locked eye-level camera holds
a steady waist-up profile two-shot with both faces unobstructed in soft window
light. At the beginning, the woman leans forward slightly and moves her lips for
one brief question while the man watches with his mouth closed. They pause and
maintain eye contact. In the second half, the man nods once and moves his lips
for one brief reply while the woman watches with her mouth closed. The shot
remains stable, simple, and realistic throughout.
```

台詞本文は prompt に含めず、駆動音声だけに入れる。これにより、台詞を画面上の字幕として
描こうとする可能性を減らせた。

## 駆動音声

映像の尺に合わせた WAV を先に作る。今回良好だった 10.041667 秒の音声には、次の発話
区間を設けた。

| 区間 | 内容 |
|---|---|
| 0.00–0.71 秒 | 無音 |
| 0.71–1.60 秒 | 女性の質問 |
| 1.60–5.21 秒 | 無音 |
| 5.21–6.95 秒 | 男性の返答 |
| 6.95–10.04 秒 | 無音 |

無音区間は、モデルが話者交替を映像へ反映するための時間として使う。発話を詰めて連結
せず、各話者の前後に余裕を残す。

音声の作成方法は [`research-assets.md`](research-assets.md) のボイス音声を参照する。
入力 WAV の原稿、話者、速度、sample rate、channel、各発話の開始時刻を記録する。

## A2V の実行

まず音声を Files API へアップロードする。

```sh
api_base_url=${KIAPI_BASE_URL:-http://localhost:8500}

audio_id=$(
  curl -fsS -X POST "$api_base_url/v1/files" \
    -F 'file=@driving-dialogue.wav;type=audio/wav' |
    jq -er '.file_id'
)
```

10 秒、512 x 512、24 fps の例。長い処理では `async` を使う。

```sh
jq -n \
  --arg audio_id "$audio_id" \
  --arg prompt 'Inside a quiet room with a smooth warm beige wall, a young woman in a plain green sweater stands on the left and a young man in a plain blue shirt stands on the right. Only these two people are present. A locked eye-level camera holds a steady waist-up profile two-shot with both faces unobstructed in soft window light. At the beginning, the woman leans forward slightly and moves her lips for one brief question while the man watches with his mouth closed. They pause and maintain eye contact. In the second half, the man nods once and moves his lips for one brief reply while the woman watches with her mouth closed. The shot remains stable, simple, and realistic throughout.' \
  '{
    model: "distilled",
    mode: "async",
    prompt: $prompt,
    audio: {type: "file_id", file_id: $audio_id},
    width: 512,
    height: 512,
    num_frames: 241,
    fps: 24,
    seed: 7302030,
    generate_audio: false
  }' |
  curl -fsS -X POST "$api_base_url/v1/video/ltx2/generate" \
    -H 'Accept: application/json' \
    -H 'Content-Type: application/json' \
    --data-binary @- |
  jq
```

`num_frames` は `1 + 8 * k` とし、241 frames / 24 fps は約 10 秒になる。A2V では
`generate_audio=false` にする。`audio` と `generate_audio=true` は同時に指定できない。

## 出力の検証

API の `has_audio=true` だけで成功と判断しない。少なくとも stream、音量、発話区間、
代表 frame を確認する。

```sh
ffprobe -v error \
  -show_entries \
  format=duration,size:stream=index,codec_type,codec_name,sample_rate,channels,width,height,r_frame_rate,duration \
  -of json output.mp4

ffmpeg -nostdin -hide_banner -i output.mp4 \
  -vn -af volumedetect -f null - 2>&1

ffmpeg -nostdin -hide_banner -i output.mp4 \
  -vn -af silencedetect=noise=-40dB:d=0.25 -f null - 2>&1

ffmpeg -nostdin -loglevel error -y -i output.mp4 \
  -vf 'fps=1,scale=256:256,tile=10x1' -frames:v 1 contact-sheet.jpg
```

確認項目は次のとおり。

- MP4 に video と audio の両 stream がある
- 音声が無音または極端に小さくない
- 入力 WAV と MP4 の発話区間が一致する
- 台詞全文と話者順が保たれている
- 発話中の人物と口元の変化が対応する
- 人数、構図、背景が prompt と一致する
- 字幕、ロゴ、意味不明な文字、frame border がない

## 観測結果

2026-07-30 に kiapi 0.5.3、LTX-2 distilled、512 x 512、24 fps で比較した。

| 試行 | 条件 | 観測 |
|---|---|---|
| T2V+Audio、6.7 秒 | 台詞全文を prompt に記載 | 音声付き MP4 は生成できたが、第一発話だけが聞き取れ、意味不明な字幕が出た |
| T2V+Audio、10 秒 | 発話時刻と文字抑制を詳細に記載 | audio stream はあったが平均 -71.3 dB の実質無音で、意味不明な字幕も出た |
| A2V、10 秒、書店 | 台詞を既知音声で入力 | 両台詞を保持したが、上下に偽ロゴと偽文字を含む frame border が出た |
| A2V、10 秒、無地の部屋 | 簡潔な positive prompt | 二人、話者交替、両台詞を保持し、文字 artifact は観測しなかった |

最後の試行は 127 秒で生成され、10.041667 秒の H.264 + AAC MP4 になった。代表 frame
と音声認識では、女性の質問、間、男性の返答に対応する口元の変化を確認した。終盤に
女性が左端へ寄る小さな framing drift は残ったため、人物位置をさらに固定する場合は、
二人の構図を持つ開始画像を追加した A2V+I2V を次に試す。

## FFmpeg と background service

LTX-2 は一時 video と WAV を FFmpeg で mux する。launchd で動く kiapi service から
FFmpeg を発見できないと、音声を生成しても無音 MP4 へ fallback する。

kiapi 0.5.3 以降の `service install` は、実行時の `PATH` を plist に保存する。FFmpeg を
インストールした shell から service を再登録する。

```sh
command -v ffmpeg
kiapi service stop
kiapi service uninstall
kiapi service install
kiapi service start
kiapi service status
```

再登録後は `service show` で `PATH` を確認し、実際の MP4 を `ffprobe` で検査する。

## 制約

- distilled model の 1 seed だけでは品質を保証できない。構図が重要なら seed sweep を行う
- 二人の口元を frame で定性的に確認しただけで、音素単位の lip sync は測定していない
- `say` の音声は動作確認向けであり、自然な演技には別の TTS と調整が必要になる
- A2V でも人物の移動や framing drift は起こる
- 文字を避けやすい場面へ変更した結果であり、文字抑制そのものを解決したわけではない

## 参考資料

- [LTX-2 official repository](https://github.com/Lightricks/LTX-2)
- [LTX-2 official prompting guide](https://ltx.io/blog/prompting-guide-for-ltx-2)
- [LTX-2 model card](https://huggingface.co/Lightricks/LTX-2)
- [LTX-2 official pipeline reference](https://github.com/Lightricks/LTX-2/blob/main/packages/ltx-pipelines/docs/pipelines.md)
- [mlx-video](https://github.com/Blaizzy/mlx-video)
