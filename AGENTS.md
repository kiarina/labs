# AGENTS.md

このリポジトリで作業するエージェント向けのガイドラインです。

## リポジトリの目的

`labs` は、公開可能な調査・実験・検証コードを置くモノレポです。
各 lab は、小さく独立したプロジェクトとして成立させ、別の lab に暗黙に依存させないでください。

## ディレクトリ構成

- lab は `YYYY/MM/DD/{slug}/` に作成する
- 各 lab に `README.md`、`metadata.json`、`.gitignore` を置く
- lab 固有の task は、その lab の `.mise/tasks/` に置く
- 大きな画像、動画、データセット、バイナリは Git に追加しない
- 共有アセットはルートの `assets/` にダウンロードして使用する

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
- ルートの `README.md` は生成物なので、プロジェクト一覧を直接編集しない
- `metadata.json` を追加・変更したら `make build-readme` を実行する
- `.mise/tasks/test-assets/download` は
  `kiarina/test-assets` からコピーしたファイルとして維持し、独自変更しない
- test assets のバージョンは Makefile 冒頭の `RELEASE_VERSION` と
  `ASSETS_VERSION` で固定する

## コマンド

```sh
# 全 lab のデフォルト task を実行
make

# metadata.json からルート README を再生成
make build-readme

# 固定バージョンの共有アセットを assets/ に取得
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
- `assets/` やその他の重い生成物が Git の追跡対象に入っていないことを確認する
