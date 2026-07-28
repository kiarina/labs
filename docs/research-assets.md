# 研究用アセットの作成

研究で使用する画像とボイス音声は、次の方法で作成する。
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

## 共有アセットとして登録する

大きな画像や音声をこのリポジトリへ直接追加しない。生成物は
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
