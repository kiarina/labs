# 研究用アセットの作成

研究で使用する画像、音声、動画は、次の方法で作成する。
生成物だけでなく、追試に必要な入力、設定、実行環境、失敗した試行も記録する。

## 共通方針

- 既存の著作物、商標、実在人物の肖像や声を利用するときは、利用条件を確認する
- プロンプトや読み上げ原稿に秘密情報、個人情報、API キーを含めない
- 採用した生成物について、使用したツールまたはモデル、入力、設定、生成日を
  lab の README などに記録する
- 複数候補から選んだ場合は、候補数と選定基準を記録する
- 期待どおりにならなかった生成や、手作業で行った後処理も省略せず記録する
- API キーや認証情報は Git に追加しない

## 画像

OpenAI Image API の `gpt-image-2` で作成する。API キーは環境変数
`OPENAI_API_KEY` に設定済みであることを前提とする。

```sh
if [ -z "${OPENAI_API_KEY:-}" ]; then
  echo "OPENAI_API_KEY is not set" >&2
  exit 1
fi
```

Python SDK を使う場合は、次のように生成する。プロンプトは検証対象、構図、画風、
照明、背景、含めない要素などを、研究目的に必要な範囲で具体的に書く。

```sh
python -m pip install openai
```

```python
import base64

from openai import OpenAI


client = OpenAI()
prompt = """
研究に必要な画像の説明をここに書く。
"""

result = client.images.generate(
    model="gpt-image-2",
    prompt=prompt,
    size="1024x1024",
    quality="medium",
)

image_bytes = base64.b64decode(result.data[0].b64_json)
with open("asset.png", "wb") as output:
    output.write(image_bytes)
```

まず `quality="low"` で構図を確認し、採用候補だけを `medium` または `high` で
生成すると、試行時間と費用を抑えやすい。`gpt-image-2` は透過背景をサポート
しないため、必要なら生成後の背景除去を別工程として記録する。

少なくとも次を記録する。

- モデル名: `gpt-image-2`
- プロンプト全文
- `size`、`quality`、出力形式など、デフォルト以外を含む生成パラメータ
- SDK のバージョンと実行日
- 生成した候補数、採用したファイル、選定基準
- リサイズ、圧縮、切り抜き、背景除去などの後処理
- API エラーやモデレーションによる失敗と、その後に変更した条件

API の仕様や対応するサイズは変わり得るため、作成時に
[OpenAI の Image generation ガイド](https://developers.openai.com/api/docs/guides/image-generation)
を確認する。

## ボイス音声

ボイス音声は、macOS 標準の `say` または VOICEVOX で作成する。
短い動作確認や OS 標準音声で十分な検証には `say`、話者とスタイルを明示して
日本語音声を作る検証には VOICEVOX を使う。

### macOS `say`

読み上げ原稿を UTF-8 のテキストファイルに保存して生成する。

```sh
say -f script.txt \
  -o voice.wav \
  --file-format=WAVE \
  --data-format=LEI16
```

AAC が必要な場合は次のようにする。

```sh
say -f script.txt -o voice.aac --data-format=aac
```

macOS の音声や言語を固定する必要がある場合は、利用可能な音声を確認して `-v` で
指定する。

```sh
say -v '?'
say -v Kyoko -f script.txt -o voice.aiff
```

再現性のため、読み上げ原稿、`say` の引数、選択した音声名、macOS のバージョンを
記録する。OS 更新で音声の実装が変わる可能性があるため、厳密な比較では生成済みの
音声を固定して使う。

### VOICEVOX

VOICEVOX Engine をローカルで起動する。

```sh
docker run -d \
  --name voicevox-engine \
  --restart unless-stopped \
  -p 50021:50021 \
  voicevox/voicevox_engine:cpu-latest
```

利用可能な話者名、スタイル名、speaker ID を確認する。

```sh
curl -s http://127.0.0.1:50021/speakers |
  jq -r '.[] as $speaker | $speaker.styles[] | "\(.id)\t\($speaker.name)\t\(.name)"'
```

次の例は speaker ID `3` を使用し、発話の前に 0.1 秒、後ろに 0.8 秒の無音を
設定して WAV を生成する。研究ごとに speaker ID と無音長を明示する。

```sh
speaker_id=3
text='読み上げる文章をここに書く。'

curl -s -X POST \
  "http://127.0.0.1:50021/audio_query?speaker=${speaker_id}" \
  --get \
  --data-urlencode "text=${text}" \
  -o audio-query.json

jq '.prePhonemeLength = 0.1 | .postPhonemeLength = 0.8' \
  audio-query.json > audio-query-padded.json

curl -s \
  -H 'Content-Type: application/json' \
  -X POST \
  -d @audio-query-padded.json \
  "http://127.0.0.1:50021/synthesis?speaker=${speaker_id}" \
  -o voice.wav
```

少なくとも次を記録する。

- 読み上げ原稿
- `say` または VOICEVOX のどちらを使用したか
- 音声名、または VOICEVOX の Engine バージョン、話者名、スタイル名、speaker ID
- 速度、抑揚、音高、無音長など、音声クエリに加えた変更
- 出力形式、サンプルレート、チャンネル数
- ノイズ除去、音量正規化、切り出し、形式変換などの後処理

VOICEVOX を再現可能な条件に固定するときは、`cpu-latest` のままにせず、検証時に
使用したイメージのバージョンまたは digest を記録する。

## 音楽、効果音、動画に共通する準備

音楽、効果音、動画は、ローカルで動作する kiapi を使用して作成する。生成前に
サービスが利用可能であることを確認する。

```sh
curl -fsS http://localhost:8500/health | jq
```

リクエストやモデルの仕様は、生成時点の OpenAPI を正とする。共通仕様から各機能の
OpenAPI URL を確認し、lab の README には `info.version` も記録する。

```sh
curl -fsS http://localhost:8500/openapi.json | jq '.info, .paths'

curl -fsS http://localhost:8500/v1/audio/acestep/openapi.json | jq '.info, .paths'
curl -fsS http://localhost:8500/v1/audio/audiogen/openapi.json | jq '.info, .paths'
curl -fsS http://localhost:8500/v1/video/ltx2/openapi.json | jq '.info, .paths'
```

各生成 API は `mode` に `sync` または `async` を指定できる。以下では、生成物を
直接ファイルへ保存できる `sync` を使用する。長い生成でタイムアウトする場合は
`async` を指定し、返された `job_id` を使って状態を確認する。

```sh
curl -fsS "http://localhost:8500/v1/jobs/{job_id}" | jq
```

完了した job の `artifacts` に含まれる `file_id` から生成物を取得できる。

```sh
curl -fsS \
  "http://localhost:8500/v1/files/{file_id}/download" \
  -o asset.bin
```

## 音楽

音楽は ACE-Step で作成する。利用可能なモデルは生成時に確認する。

```sh
curl -fsS http://localhost:8500/v1/audio/acestep/models | jq
```

`turbo` は試作向け、`xl-base` は品質を優先する生成向けに使う。プロンプトには
ジャンル、テンポ、楽器、雰囲気、制作上の特徴など、求める音を文章で記述する。
歌詞なしの場合は `lyrics` に `[Instrumental]` を指定する。

```sh
curl -fsS -X POST \
  http://localhost:8500/v1/audio/acestep/generate \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "turbo",
    "mode": "sync",
    "seed": 1234,
    "prompt": "Warm ambient electronica, 90 BPM, soft synthesizer pads, restrained percussion, seamless loop-like ending",
    "lyrics": "[Instrumental]",
    "duration": 30,
    "lang": "ja"
  }' \
  -o music.wav
```

ボーカル曲では、`[Verse 1]`、`[Chorus]`、`[Bridge]` などのセクションタグを
各行の先頭に付け、`lang` に歌唱言語の ISO 639-1 コードを指定する。歌詞の量は
`duration` に合わせる。

少なくとも次を記録する。

- kiapi のバージョンと ACE-Step のモデル名
- プロンプトと歌詞の全文
- `duration`、`lang`、seed
- `inference_steps`、`guidance_scale`、`shift` を変更した場合はその値
- 採用した候補と選定基準、編集やループ加工などの後処理

## 効果音

短い非音楽音声は AudioGen で作成する。雨、足音、衝撃音、機械音、環境音などに
使用し、音楽には ACE-Step を使用する。利用可能なモデルを生成時に確認する。

```sh
curl -fsS http://localhost:8500/v1/audio/audiogen/models | jq
```

プロンプトには、音源、接触する材質、距離、空間、強さ、環境音など、聞こえる特徴を
具体的に記述する。

```sh
curl -fsS -X POST \
  http://localhost:8500/v1/audio/audiogen/generate \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "medium",
    "mode": "sync",
    "prompt": "A single heavy wooden door closing in a small stone room, close microphone, short natural reverberation",
    "duration": 5,
    "seed": 1234,
    "top_k": 250,
    "top_p": 0,
    "temperature": 1,
    "cfg_coef": 3
  }' \
  -o sound-effect.wav
```

少なくとも次を記録する。

- kiapi のバージョンと AudioGen のモデル名
- プロンプト全文
- `duration`、seed、`top_k`、`top_p`、`temperature`、`cfg_coef`
- 生成した候補数、採用基準、音量調整や切り出しなどの後処理

## 動画

動画は LTX-2 で作成する。利用可能なモデルは生成時に確認する。
会話動画の A2V、prompt、検証方法については
[`ltx-2-video-generation.md`](ltx-2-video-generation.md)も参照する。

```sh
curl -fsS http://localhost:8500/v1/video/ltx2/models | jq
```

プロンプトには、被写体だけでなく、動き、カメラワーク、構図、照明、画質を肯定形で
記述する。次の例は、テキストだけから 512 x 512、24 fps、97 フレームの MP4 を
生成する。

```sh
curl -fsS -X POST \
  http://localhost:8500/v1/video/ltx2/generate \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "distilled",
    "mode": "sync",
    "prompt": "A paper pinwheel turning slowly in a gentle breeze, static close-up camera, soft daylight, natural motion",
    "width": 512,
    "height": 512,
    "num_frames": 97,
    "fps": 24,
    "seed": 1234,
    "generate_audio": false
  }' \
  -o video.mp4
```

`width` と `height` は 64 の倍数にする。`num_frames` は `1 + 8 * k` を満たす値に
し、動画の長さは `num_frames / fps` 秒になる。

最初のフレームや動画を駆動する音声を指定する場合は、先に Files API へアップロード
する。

```sh
curl -fsS -X POST \
  http://localhost:8500/v1/files \
  -F 'file=@first-frame.png' | jq

curl -fsS -X POST \
  http://localhost:8500/v1/files \
  -F 'file=@driving-audio.wav' | jq
```

返された ID を `image` または `audio` の FileRef として生成リクエストへ追加する。
終端フレームには `end_image` を使う。`audio` と `generate_audio=true` は同時に
指定できない。

```json
{
  "image": {
    "type": "file_id",
    "file_id": "file_0123456789abcdef"
  },
  "audio": {
    "type": "file_id",
    "file_id": "file_fedcba9876543210"
  }
}
```

少なくとも次を記録する。

- kiapi のバージョンと LTX-2 のモデル名
- プロンプト全文
- 生成モードと、入力に使用した画像または音声
- `width`、`height`、`num_frames`、`fps`、seed
- `image_strength`、`end_image_strength`、`generate_audio`
- 生成した候補数、採用基準、編集、音声差し替え、再エンコードなどの後処理

## 共有アセットとして登録する

大きな画像、音声、動画をこのリポジトリへ直接追加しない。生成物は
`kiarina/test-assets` で管理し、リリース後にこのリポジトリへ取得する。

JPEG 画像の場合は、ファイル名を `{slug}_{w}x{h}_{size}kb.jpg` とし、
`kiarina/test-assets` の `src/v1/labs-assets-v1/jpg/` に配置する。そのリポジトリで
次を実行する。

```sh
mise run build v1
mise run release v1
```

続いて、このリポジトリで共有アセットを取得する。

```sh
make download-test-assets
```

`tests/assets/jpg/` に対象ファイルがコピーされたことを確認する。lab の task から
共有アセットを使う場合は、最初にダウンロード task を実行する。

```sh
mise run //:test-assets:download
```

`tests/assets/` 以下の大きな生成物が Git の追跡対象になっていないことも確認する。
