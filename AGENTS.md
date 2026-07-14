# AGENTS.md

このリポジトリで作業するエージェント向けのガイドラインです。

## リポジトリの目的

`labs` は、公開可能な調査・実験・検証コードを置くモノレポです。
各 lab は、小さく独立したプロジェクトとして成立させ、別の lab に暗黙に依存させないでください。
これまでに行ったプロジェクトの一覧を `README.md` にまとめていますので、最初に確認してください。

## ディレクトリ構成

- lab は `YYYY/MM/DD/{slug}/` に作成する
- 各 lab に `README.md`、`metadata.json`、`.gitignore` を置く
- lab 固有の task は、その lab の `.mise/tasks/` に置く
- 大きな画像、動画、データセット、バイナリは Git に追加しない
- 共有アセットはルートの `tests/assets/` にダウンロードして使用する

`metadata.json` は次の形式です。

```json
{
  "title": "Human-readable project title",
  "tags": ["tag-a", "tag-b"]
}
```

## 作業時のルール

- 新しい lab は、それ単体で目的、実行方法、結果が分かる README を用意する
- コードと設定は再現可能な最小構成にし、生成物や一時ファイルは
  lab の `.gitignore` に追加する
- 他の lab のコードを直接 import・参照しない。必要なら各 lab 内に閉じる
- 既存の lab を変更するときは、その lab の規約と toolchain を優先する
- ルートの `README.md` と `tags/*.md` は生成物なので、直接編集しない
- `metadata.json` を追加・変更したら `make build-readme` を実行する
- `.mise/tasks/test-assets/download` は
  `kiarina/test-assets` からコピーしたファイルとして維持し、独自変更しない
- `tests/assets/` 以下のファイルを使う検証では、
  `mise run` 時に `mise run //:test-assets:download` を最初に実行する
- ローカル環境のパスが漏洩しないように、README やスクリプト中では、
  絶対パスを使わず、相対パスや環境変数を使う

## 研究に生成したメディアを使う場合の手順

画像・音声・動画などのメディアを生成して研究に使う場合、下記の手順でファイルを管理してください。

jpg の例:
- ファイル名を `{slug}_{w}x{h}_{size}kb.jpg` の形式にする
- ~/src/github.com/kiarina/test-assets/src/v1/labs-assets-v1/jpg/ にファイルを配置する
- `cd ~/src/github.com/kiarina/test-assets && mise run build v1 && mise run release v1` を実行する
- このプロジェクトで `make download-test-assets` を実行し、`tests/assets/jpg/` にファイルがコピーされることを確認する

## 検証の方針

この方針は、新しい lab と、検証内容を実質的に変更する既存の lab に適用します。
既存の lab を、この方針への適合だけを目的として一括で変更する必要はありません。
README の構成は固定せず、検証内容に応じて読みやすい形を選んでください。

次の事項は必須です。

- 検証を始める前に、目的、明らかにしたい問い、評価方法を定める
- 入力、検証条件、依存関係のバージョン、実行手順、実行環境など、
  第三者が追試するために必要な情報を記録する
- 実際に観測した事実と、それに対する解釈や推測を区別して記述する
- 期待に反する結果、失敗した試行、都合の悪い結果も省略しない
- 結論が成立する範囲、未確認の事項、既知の制約を明示する
- 複数の対象を比較するときは可能な限り条件を揃え、
  揃えられない条件とその影響を記録する

乱数や実行ごとの変動が結果に影響する場合は、再現に必要な seed、
試行回数、結果のばらつきを記録することを推奨します。

## コマンド

```sh
# 全 lab のデフォルト task を実行
make

# metadata.json からルート README を再生成
make build-readme

# 固定バージョンの共有アセットを tests/assets/ に取得
make download-test-assets

# ひとつの lab だけを実行
mise -C YYYY/MM/DD/{slug} run
```

全 lab の実行は将来重くなる可能性があります。変更した lab の task を先に実行し、
必要な場合にルートの `make` で全体を確認してください。

## 完了前の確認

- 変更対象の task・テストを実行する
- `make build-readme` を実行し、生成差分を含める
- `git diff --check` で whitespace error がないことを確認する
- `tests/assets/` やその他の重い生成物が Git の追跡対象に入っていないことを確認する
