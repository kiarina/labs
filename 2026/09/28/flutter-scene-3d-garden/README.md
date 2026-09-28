# A human-scale 3D garden with VRM 1.0 avatars on flutter_scene

2D のマップチップで描いていた「箱庭」（複数のキャラクターが住む部屋）を、Flutter の 3D エンジン
[flutter_scene](https://pub.dev/packages/flutter_scene) で等身大の 3D にし、キャラクターを VRM 1.0 にできるかを確かめます。
普段はクォータービューで上から見て、キャラクターをタップするとその顔の前にカメラが移る、という見せ方を想定しています。

## Purpose

1. macOS・Windows・Android・iOS・Web の 5 つで、同じコードの箱庭が描けるか
2. タップ・1 本指ドラッグ・ピンチ・ひねり・ホイール・右ドラッグで視点を動かせるか。クォータービュー ↔ キャラの正面ビューを滑らかに切り替えられるか
3. VRM 1.0 を flutter_scene の glTF の読み込みにそのまま渡せるか。VRM 拡張（`VRMC_vrm`）を自分で読んで、骨（humanoid）で座る・寝る姿勢を作り、
   表情（expression）でまばたき・口を動かせるか
4. 何体まで並べられるか（fps、読み込み時間、メモリ）

## Answer

- **5 つとも描けました。** 同じ Dart のコードで、箱庭・VRM・影・ラベル（Flutter の Widget を 3D の座標に重ねたもの）が出ます
- **操作は、試した範囲では期待どおりに動きました。** iOS Simulator で 2 本指のピンチ・ひねり、1 本指ドラッグ、タップでの選択、Chrome でクリック・ホイール・ドラッグを
  確かめました。Android の実機と Windows では手で触っていません（下の「未確認」）
- **VRM 1.0 は、普通の glTF として読み込めました。** 手元の 5 体（VRoid のサンプル 4 体と、Tripo から作った 1 体）はどれも VRM 拡張を
  `extensionsUsed` にしか載せておらず、flutter_scene は警告を出して読み飛ばします。拡張の JSON は自分で GLB から読み、**glTF のノード番号と
  flutter_scene のノードが 1 対 1 で同じ順に並ぶ**ことを使って対応づけられました（名前も一致を確認）。骨で座る・寝る、morph でまばたき・口、
  UV をずらす表情（`textureTransformBinds`）まで動きました
- **重さは端末で大きく分かれます。** 5 体・影あり・テクスチャ 1024 px で、M1 Max は 120 fps（上限）、RTX 3080 Ti は 125〜144 fps、iPad Air 4 は 33 fps
  （影なしなら 60 fps の上限）、Chrome（M1 Max）は 50 fps、**Pixel 6 は 6.5 fps、Pixel Fold は 13.1 fps** でした。Pixel 6 は VRM を 1 体も置かない箱庭だけでも 18.6 fps で、
  VRM ではなくエンジンの基本の描画コストが原因です。未公開の master では Pixel 6 が 14.8 fps、Pixel Fold が 28.1 fps（影なしで 39.8 fps）まで上がりました
- **影が一番高くつきます。** 20 体で影を切ると、M1 Max は 64 → 116 fps、Chrome は 16 → 62 fps、RTX 3080 Ti は 57 → 102 fps になりました
- **メモリは VRoid 1 体あたり 200 MB 前後**（M1 Max の実測、1024 px に縮めた後）で、iPad Air 4（4 GB）は 16 体目の読み込み中に OS に落とされました
- **1 体の読み込みに 0.5〜3 秒かかり、その間は画面が止まります**（Web で最大 1.7 秒、Windows の初回は最大 9.7 秒）。Pixel 6 は 1 体 5〜24 秒でした

## Setup

- Flutter 3.47.2（`.mise.toml`）、flutter_scene 0.23.0（pub の最新、2026-08-25）。比較用に GitHub の master（`b02c999`、未公開の 0.24.0）でも一部を測りました
- Flutter GPU を各 OS で有効にしています（iOS・macOS の `Info.plist` の `FLTEnableFlutterGPU`、Android の `AndroidManifest.xml` の meta-data、
  Windows の `project.set_enable_flutter_gpu(true)`。Web は設定なし）
- VRM は 5 体。Tripo と Blender で作った 1 体（非公開）と、VRoid 公式のサンプル `AvatarSample_A`〜`D`（再配布不可）。**どちらもこのリポジトリには
  入れていません。** `mise run prepare-vrm` で手元のファイルを `app/assets/vrm/` にコピーします。`MAX_EDGE=1024` を付けると
  `app/tool/shrink_vrm.dart` がテクスチャの長辺を 1024 px に縮めた GLB を書きます（計測は特に断りがなければ 1024 px）
- 6 体目からは同じ 5 ファイルを順に読み直します（毎回別のメッシュ・テクスチャとして読み込む。キャラクターが全員違う場合と同じ負荷）

### 箱庭

1 マス 1 m の等身大で、上にリビング（12 × 7 m）、その下に廊下、さらに下に Body の部屋（5 × 4.5 m）が 2 つ並びます。家具は直方体・円柱などの
組み込みの形だけで作ったローポリです。ソファ 2 席・椅子 4 脚・机の椅子 2 脚（座る）、ベッド 2 台（寝る）、立ち位置 5 か所の計 15 か所に順に置きます。
カメラの側にある壁は、クォータービューのときだけ腰の高さまで下げます（部屋の中を見るため）。

### VRM の扱い（`app/lib/vrm_avatar.dart`）

- 読み込みは `Node.fromGlbBytes`。VRM 拡張は GLB の JSON チャンクを別に読みます
- 姿勢は毎フレーム、骨を休止姿勢に戻してから、「この骨から子の骨への向きを、世界座標のこの向きに合わせる」回転を親から順にかけます。
  休止姿勢が T ポーズでも A ポーズでも、骨の軸の向きが揃っていなくても同じコードで座れました（Tripo 由来の 1 体は骨の軸がばらばら）
- 寝る姿勢は、体全体を仰向けに倒してから腕を下ろすだけです。脚はそのまま
- 表情は `expressions.preset` の `morphTargetBinds`（ノード番号・morph 番号・重み）と `textureTransformBinds`（マテリアル番号・UV のずれ）。
  マテリアルは、メッシュを持つノードの primitive を glTF と同じ順に対応づけて探します
- タップの判定: flutter_scene 0.23 は骨入りメッシュを**休止姿勢のまま**で当たり判定するため、座った・寝たキャラクターには当たりません。
  腰から頭までを覆う見えないカプセルを毎フレーム動かし、それに当てています

## Results

計測は `BENCH=true` のビルドが自動で行います。読み込みの後 3 秒待ち、クォータービューで 6 秒、カメラを回しながら 6 秒、1 体目の正面ビューで 6 秒、
フレームの間隔を測ります（fps は 6 秒間の平均）。数値はすべて `results/*.jsonl` にあります。

| 端末 | ビルド | 画面 |
| --- | --- | --- |
| MacBook Pro（M1 Max、64 GB）、macOS 26.6.2 | release | 1280×768 の窓、120 Hz |
| Windows PC（Core i9-12900K、GeForce RTX 3080 Ti、64 GB） | release | 1266×682 の窓 |
| Chrome 153（上の MacBook Pro） | release（dart2js） | 1280×773 の窓。専用の窓で、裏に回っても間引かれない設定 |
| iPad Air（第 4 世代、A14、4 GB）、iPadOS 26.6.2 | profile | 820×1180、60 Hz |
| Pixel 6（Tensor G1、Mali-G78、8 GB）、Android 17 | profile | 端末の画面全体（1080×2400） |
| Pixel Fold（Tensor G2、Mali-G710、12 GB）、Android 17 | profile | 畳んだ状態の外側の画面（1080×2092） |

### fps（クォータービュー / 回転中 / 正面ビュー）

| 端末 | 5 体・影あり | 10 体・影あり | 20 体・影あり | 10 体・影なし | 20 体・影なし |
| --- | --- | --- | --- | --- | --- |
| macOS | 120 / 120 / 120 | 120 / 120 / 120 | 64 / 65 / 71 | – | 116 / 116 / 119 |
| Windows | 125 / 130 / 144 | 76 / 78 / 106 | 57 / 57 / 61 | – | 102 / 103 / 133 |
| Web（Chrome） | 50 / 51 / 47 | 26 / 25 / 46 | 16 / 16 / 24 | 81 / 81 / 97 | 62 / 61 / 76 |
| iPad Air 4 | 33 / 36 / 31 | 31 / 31 / 29 | – | 60 / 60 / 60 | **16 体目で落ちた** |
| Pixel 6 | 6.5 / 7.3 / 3.0 | 4.8 / 4.8 / 2.8 | – | 8.9 / 9.5 / 4.0 | 9.1 / 10.6 / 3.5 |
| Pixel Fold | 13.1 / 13.7 / 4.6 | 7.9 / 8.4 / 7.3 | – | 26.1 / 27.0 / 14.3 | 12.5 / 16.0 / 9.9 |

- macOS の 5 体・10 体は 120 Hz の上限、iPad の影なしは 60 Hz の上限に張り付いています
- macOS の 20 体・影ありで、姿勢の計算を止めても（`FREEZE=true`）67 fps で変わりませんでした。Dart 側の計算ではなく描画、特に影が重いと読めます

### Pixel 6 が遅い理由を切り分けた

| 条件（5 体・影なし） | クォータービュー | 正面ビュー |
| --- | --- | --- |
| そのまま | 7.3 | 4.6 |
| **VRM なし（箱庭だけ）** | **18.6** | – |
| 描画の解像度を 1.0 倍（端末は 2.875 倍） | 10.2 | 7.0 |
| アンチエイリアスなし | 8.8 | 3.6 |
| 姿勢の計算を止める | 6.1 | 4.1 |

体数を 5 → 20 に増やしても fps はほとんど変わらず（7.3 → 9.1）、キャラクターが画面いっぱいになる正面ビューが一番遅いことから、
**画素あたりのコストか、フレームごとの固定のコストが大きい**と推測しています。flutter_scene の未公開の 0.24.0 の変更履歴には、Mali の GPU で
シェーダーを半精度にする、Vulkan で GPU 待ちが UI スレッドを止めないようにする、など関係しそうな修正が並んでいます。master での計測は下の節。

### メモリ（macOS の phys_footprint）

| | 5 体 | 10 体 | 20 体 |
| --- | --- | --- | --- |
| テクスチャそのまま（最大 2048 px） | 1,936 MB | 3,405 MB | 6,948 MB |
| 1024 px に縮めた | 1,215 MB | 2,054 MB | 4,275 MB |

VRoid のサンプルは 1 体に 2048 px の画像が 4〜10 枚あり、RGBA とミップマップで 130〜290 MB と見積もれます。縮めても 1 体あたり約 200 MB 残るので、
テクスチャ以外（メッシュ、morph、読み込み時の CPU 側の複製）も大きいと考えられますが、内訳は測っていません。
iPad Air 4 は 20 体（1024 px）の 16 体目で `signal 9`（OS によるメモリ不足の終了）になりました。

### 読み込み

1 体の `Node.fromGlbBytes`（1024 px）: macOS 0.5〜2.0 秒、Windows 0.7〜1.9 秒、Chrome 0.8〜3.1 秒（20 体では最大 5.5 秒）、iPad 1.0〜3.7 秒（10 体・影ありの回だけ最初の 3 体が 6〜10 秒）、
Pixel 6 5.6〜24 秒。テクスチャそのままでは macOS で 1.7〜4.5 秒でした。

**読み込み中は画面が止まります。** 読み込み中の最長のフレームは macOS 108 ms、Chrome 1.3〜1.7 秒、iPad 0.1〜1.5 秒でした。
Windows は影ありの初回だけ、最初の 2 体が 6 秒・11 秒かかり、その間に 9.7 秒止まったフレームがありました（2 回とも同じ。影なしでは最初の 1 体が 2.8 秒）。

### flutter_scene の master（未公開の 0.24.0）

Web は master でも測りました（`results/web-master-b02c999.jsonl`）。

| Chrome、5 体 | 0.23.0 | master |
| --- | --- | --- |
| 影あり | 50 / 51 / 47 fps、読み込み 1.1〜3.1 秒 | **18 / 18 / 13 fps**、読み込み 0.5〜1.3 秒 |
| 影なし | – | 76 / 74 / 50 fps、読み込み 0.2〜0.9 秒 |

master は読み込みが 2〜5 倍速くなった一方、影ありの描画は 0.23.0 の 3 分の 1 でした。master の Web ビルドでは `onTick` に渡る間隔からフレームを数えられなかった（0 件になった）ため、途中からフレームの間隔を
自前の Stopwatch で測るようにしました。Web・Windows・iPad・Pixel の数値はすべてこの方法で、macOS の数値だけはそれ以前の `onTick` の間隔で測っています。

Android も master で測りました（`results/android-master-b02c999.jsonl`）。fps はクォータービュー / 回転中 / 正面ビュー。

| | Pixel 6・0.23.0 | Pixel 6・master | Pixel Fold・0.23.0 | Pixel Fold・master |
| --- | --- | --- | --- | --- |
| 箱庭だけ | 18.6 | 39.6 | 24.3 | 48.2 |
| 5 体・影なし | 7.3 / 7.5 / 4.6 | 20.4 / 21.8 / 14.3 | 20.3 / 22.7 / 10.3 | **39.8 / 41.4 / 37.0** |
| 5 体・影あり | 6.5 / 7.3 / 3.0 | 14.8 / 14.7 / 12.8 | 13.1 / 13.7 / 4.6 | **28.1 / 26.4 / 24.9** |
| 1 体の読み込み（5 体・影なし） | 7〜19 秒 | 3〜6 秒 | 3.6〜8.5 秒 | 2.5〜4.0 秒 |

- **master で 2〜3 倍になりました。** 特に正面ビュー（キャラクターが画面いっぱい）が大きく改善し、画素あたりのコストが下がったと読めます
- Pixel Fold は Pixel 6 のおよそ 2 倍です。それでも 60 fps には届きません
- Pixel Fold・0.23.0 の 10 体・影なし（26.1）が 5 体・影なし（20.3）より速いのは、端末の温度やクロックの揺れと推測しています（各 1 回の計測）

## 見つかったこと

- **glTF のサンプラーの wrap（`CLAMP_TO_EDGE` など）が効きません。** 0.23.0 も master も、`PhysicallyBasedMaterial` は常に `repeat` でテクスチャを読みます
  （読み込み時に `wrapS` / `wrapT` は解析している）。Tripo 由来の 1 体は、まぶたを UV をずらして閉じる作りで、閉じたときにまぶたの画像が
  繰り返して黒い斑点になりました
- **骨入りメッシュの当たり判定は休止姿勢**（0.23.0 のドキュメントどおり）。姿勢を変えるキャラクターには代わりの当たり判定が要ります
- VRM の MToon は読まれず、通常の PBR として描かれます。VRoid のサンプルは見られる範囲ですが、目のハイライトなど重ねて描く部分が崩れる箇所がありました
- Chrome のタブが裏に回ると `requestAnimationFrame` が 1 fps 程度に間引かれ、読み込みも 5 倍ほど遅く見えます。Web の計測は、専用の窓で
  `--disable-backgrounding-occluded-windows` などを付けて行う必要がありました（`mise run bench-web`）
- macOS で窓が眠っている外部ディスプレイに復元されると、SceneView の tick が止まって計測が 0 フレームになりました。窓を常に主ディスプレイに開くようにしています

## Requirements and run

```sh
mise run                                         # analyze
MIINEKO_VRM=... VROID_DIR=... MAX_EDGE=1024 mise run prepare-vrm
MACHINE="..." COUNTS="5 10 20" mise run bench-macos   # results/macos.jsonl に追記
MACHINE="..." mise run bench-web                      # results/web.jsonl に追記
MACHINE="..." DEVICE=<flutter の device id> RESULTS=ios mise run bench-device       # iOS / Android（profile）
MACHINE="..." WIN_HOST=user@windows-pc mise run bench-windows                       # ssh で Windows へ送って計測
cd app && flutter run --dart-define=TOUR=true    # 決まった順に視点と姿勢を切り替える（画面の確認用）
```

`--dart-define` で変えられるもの: `AVATARS`（体数）、`SHADOWS`、`BENCH`、`TOUR`、`FREEZE`、`PIXEL_RATIO`、`AA`（`none` / `msaa` / `fxaa` など）、`ROOMS`。
iOS・Android は `flutter run --profile -d <device> --dart-define=BENCH=true ...` で、ログの `BENCH {...}` を読みました。
`bench-device` と `bench-windows` は、計測に使った手元のスクリプトを後から task にまとめたものです（2026-09-28 の数値はまとめる前の同じ手順で測った。Pixel Fold の 0.23.0 の数値は `bench-device` で測った）。Windows は GUI アプリの標準出力を
回収できないため、結果を `BENCH_OUT`（既定は一時ディレクトリの `scene_garden_bench.json`）にも書きます。
Pixel 6 では、インストールのたびに Google Play プロテクトの「アプリを送信しますか」が出てインストールが止まるので、「送信しない」を押しています。

操作:

| | 動き |
| --- | --- |
| タップ / クリック | キャラクターを選ぶと正面ビューへ。ダブルタップで全体へ戻る |
| 1 本指ドラッグ / 左ドラッグ | クォータービューでは地面を動かす、正面ビューではキャラクターの周りを回る |
| ピンチ / ホイール / `+` `-` | 近づく・離れる |
| 2 本指ひねり / 右ドラッグ横 / `Q` `E` | 回す |
| 2 本指で上下 / 右ドラッグ縦 / Shift + ホイール | 見下ろす角度 |
| `W` `A` `S` `D` / 矢印、`Tab`、`Esc` | 移動、次のキャラクター、全体へ |
| 画面下の `影 ON` / `影 OFF` | 影を切り替える（見た目と fps を比べる用） |

## 未確認の事項と制約

- **Android の実機と Windows では、人の指やマウスで操作していません。** 入力の処理は全プラットフォームで同じ Dart のコード（`GestureDetector` の
  scale と `Listener`）ですが、実機の 2 本指の挙動は iOS Simulator でしか見ていません。macOS はキーボード・マウスを手で試していません
- 各条件 1 回ずつの計測です（Windows の 5 体・影ありだけ 2 回）。ばらつきは測っていません
- 低価格帯の Android は測っていません。Android が遅い原因はエンジン側と推測しています（master で 2〜3 倍になったことが根拠）が、内訳は測っていません
- メモリは macOS でしか測っていません。iPad・Pixel の上限は「落ちたかどうか」だけです
- SpringBone（髪・服の揺れ）、MToon、LookAt の設定値、NodeConstraint は実装していません。首と頭は簡単な回転でカメラを向くだけです
- 画面写真は載せていません（VRM がどちらも公開できないため）
