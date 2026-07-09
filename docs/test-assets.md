# test-assets 登録手順

labs の検証で共有アセットを使う場合は、アセット本体をこのリポジトリに
コミットせず、`kiarina/test-assets` の GitHub Release assets として管理します。

## 事前確認

- labs 側では、取得するバージョンをルート `Makefile` 冒頭の
  `RELEASE_VERSION` と `ASSETS_VERSION` で固定します。
- `assets/` はダウンロード先です。生成画像、動画、データセットなどの
  大きなファイルを Git に追加しないでください。
- `.mise/tasks/test-assets/download` は `kiarina/test-assets` からコピーした
  ファイルとして維持し、labs 側で独自変更しないでください。
- test-assets の release version は `vYYYY.MM` または `vYYYY.MM.DD` 形式です。
- asset archive 名は `{project-name}-assets-v{major}.{minor}.{patch}.tar.zst`
  形式です。labs 用は `labs-assets-vX.Y.Z.tar.zst` になります。

## 登録手順

以下は `kiarina/test-assets` リポジトリで実行します。

```sh
cd /Users/kiarina/src/github.com/kiarina/test-assets
```

1. 必要なら既存 release workspace を復元します。

   ```sh
   mise run setup v2026.07
   ```

2. labs 用 asset directory を追加します。

   ```sh
   mise run add v2026.07 labs v0.3.0
   ```

3. 作成された directory にアセットを配置します。

   ```text
   src/v2026.07/labs-assets-v0.3.0/
   ```

4. `src/v2026.07/MANIFEST.md` を確認し、必要に応じて説明を具体化します。
   `mise run add` が追加する description は汎用文なので、画像の用途、
   生成方法、ライセンス、注意点などがある場合はここに記録します。

5. release artifact を生成します。

   ```sh
   mise run build v2026.07
   ```

   このコマンドは `src/v2026.07/` 内の asset directory を
   `release/v2026.07/` に `.tar.zst` として出力し、`SHA256SUMS` と
   `MANIFEST.md` も生成します。`src/` と `release/` は test-assets 側で
   Git ignore されています。

6. 公開が必要な場合のみ、GitHub Release に upload します。

   ```sh
   mise run release v2026.07
   ```

   既存 release がある場合、同名ファイルは `gh release upload --clobber`
   により上書きされます。

## labs 側の更新

test-assets に公開した asset を labs から使う場合は、labs リポジトリで
次を更新・確認します。

1. ルート `Makefile` の `RELEASE_VERSION` と `ASSETS_VERSION` を、
   使用する release と asset version に合わせます。

2. アセットを取得します。

   ```sh
   make download-test-assets
   ```

3. lab の README に、入力アセットのパス、取得方法、バージョンを記録します。

4. `assets/` 配下のファイルが Git 追跡対象になっていないことを確認します。

   ```sh
   git status --short --ignored
   ```

## 注意点

- test-assets にローカル配置しただけでは、labs の
  `make download-test-assets` からは取得できません。GitHub Release に
  公開済みである必要があります。
- 新しい release version を作る場合は、test-assets の snapshot model に従い、
  過去 release のアセットを引き継いだうえで追加します。
- labs の各 lab では、共有アセットを `assets/` から参照し、別の lab の
  directory から直接参照しないでください。
