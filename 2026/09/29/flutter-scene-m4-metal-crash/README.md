# flutter_scene master crashes the Metal shader compiler on an M4 Max Mac

[flutter_scene](https://github.com/bdero/flutter_scene) の `master` を使ったアプリ（[flutter_vrm](https://github.com/kiarina/flutter_vrm) の
example）が、M4 Max の Mac で起動した直後に落ちました。M1 Max の Mac では同じアプリが動き、公開版の flutter_scene 0.23.0 なら
M4 Max でも動きます。どのシェーダーで、flutter_scene のどの commit から、何を変えると落ちなくなるのかを調べます。

前提の lab: [flutter-scene-3d-garden](../../28/flutter-scene-3d-garden/README.md)（flutter_scene を 5 つのプラットフォームで測った。macOS は M1 Max）。

## Purpose

1. 落ちるのはどのシェーダーか
2. flutter_scene のどの commit から落ちるか
3. M4 Max だけで起きるのか
4. 回避できるか

## 条件

- M4 Max の Mac（Mac Studio M4 Max 128GB、macOS 26.6.2 と 27.0.1、Xcode 27.0）。比べる相手は M1 Max の Mac（MacBook Pro M1 Max 64GB、macOS 26.6.2）
- Flutter 3.47.2（stable）。impellerc はその engine の artifact（`darwin-x64`）
- flutter_scene は本家の `master` の `cff220e`（2026-09-28）と `26678127`（2026-09-28、執筆時の最新）、比べる相手は `0.23.0`

## 何が起きるか

アプリは起動直後、影ありの標準の材質を初めて描くフレームで落ちます（その材質のパイプラインを作るところ）。

- Impeller のログ: `Could not create render pipeline for :Compilation failed due to an interrupted connection: XPC_ERROR_CONNECTION_INTERRUPTED. This error occurred after multiple retries.`
- その直後にアプリが `impeller::PipelineDescriptor::GetPrimitiveType()` で segfault する（`RenderPass.drawIndexed` から。パイプラインが作れなかった）
- 同時に `MTLCompilerService` が `SIGABRT` で落ちる。スタックは `llvm::report_fatal_error` ← `llvm::MCObjectStreamer::emitInstruction`
  （GPU のコード生成の中）。エラーの種類は `AGXMetalG16X Code=2`

## 1. 落ちるシェーダー

`probe/main.swift` は、MSL を 1 つずつ `MTLDevice.makeLibrary(source:)` でコンパイルし、描画パイプラインまで作る小さなツールです
（vertex には何もしない fragment を、fragment には入力を合わせた vertex を組ませる）。アプリの `.shaderbundle` から MSL を取り出し
（`scripts/extract_msl.py`）、112 個すべてを別々のプロセスで試しました。

```sh
swiftc -O probe/main.swift -o probe/probe -framework Metal
python3 scripts/extract_msl.py <app>/Contents/Frameworks/App.framework/Resources/flutter_assets/packages/*/flutter_scene_generated/metal_desktop/*.shaderbundle
for f in out/msl/*.metal; do probe/probe "$f" | tail -1; done
```

**落ちたのは 4 個で、すべて影ありの標準の材質の fragment でした。**

| シェーダー | バンドル |
| --- | --- |
| `flutter_scene_standard_fragment` | flutter_scene の base |
| `flutter_scene_standard_cube_fragment` | flutter_scene の base |
| `PhysicalOpaqueShadow` | flutter_scene の physical（`.fmat`） |
| `PhysicalOpaqueShadowCube` | flutter_scene の physical（`.fmat`） |

影なし（`*_no_shadow*`）と lightmap 付き（`*_lightmap*`）の版、MToon（flutter_vrm の `.fmat`）を含むほかの 108 個は通りました。
`MTOON=false` でもアプリが落ちたのは、この 4 個が flutter_scene 自身の標準の材質だからです。

## 2. 落ち始めた commit

`scripts/probe_standard.sh` は、flutter_scene の checkout の今の commit で `flutter_scene_standard.frag` を impellerc で MSL にし、
probe に通します（`git bisect run` に使える）。

```sh
export FLUTTER_ROOT=<Flutter SDK> LAB=$PWD
cd <flutter_scene の checkout>
git bisect start cff220e flutter_scene-0.23.0 -- packages/flutter_scene/shaders
git bisect run "$LAB/scripts/probe_standard.sh"
```

0.23.0 から `cff220e` までの 206 commit のうち、シェーダーを変えた 31 commit を二分探索しました。

| commit | 結果 |
| --- | --- |
| `0.23.0`（`0dc6ee80`） | 通る |
| `05d96e17` Keep the noise library and shared uniform blocks highp | 通る |
| **`1fa830b2` Add orthographic cameras and support them in every depth effect（2026-09-16）** | **落ちる**（最初） |
| `cff220e4` | 落ちる |
| `26678127`（執筆時の最新） | 落ちる |

`1fa830b2` の上で `material_shadow_sampling.glsl` だけを 1 つ前に戻すと通ります。変わったのは froxel のスライスを求める
`PunctualLightSlice()` で、view 空間の位置を `v_viewvector` からではなく `v_position` とカメラの軸から作り、NDC を新しい
`NdcFromViewPosition()`（`view_projection.glsl`、平行投影と透視投影の両方を扱う）で求めるようになりました。

ただし、**`cff220e` の上で `PunctualLightSlice()` を丸ごと 1 つ前の形に戻しても落ちます。** 行ごとに戻した 4 通り（`-v_viewvector` に戻す、
透視投影だけの式に戻す、`view_projection.w` を外す、平行投影との `mix` を外す）もすべて落ちました。特定の書き方が引き金なのではなく、
シェーダー全体の形しだいでコンパイラの不具合を踏むと読めます。`1fa830b2` は、それを最初に踏んだ commit です。

## 3. M4 Max だけで起きるか

同じ MSL（`cff220e4` と `26678127` の `flutter_scene_standard_fragment`）と同じ probe を、M1 Max の Mac で試しました。

| Mac | GPU（Metal のドライバ） | macOS | 結果 |
| --- | --- | --- | --- |
| Mac Studio M4 Max | `AGXMetalG16X` | 26.6.2 | 落ちる |
| Mac Studio M4 Max | `AGXMetalG16X` | 27.0.1（26A434） | 落ちる（同じ 5 つの commit で同じ結果、スタックも同じ） |
| MacBook Pro M1 Max | Apple M1 Max | 26.6.2 | 通る |

OS の版が同じで、GPU の世代だけが違います。**M4 世代（G16）の Metal コンパイラの不具合**で、執筆時点の最新の正式版（27.0.1）でも直っていません。
M2・M3 は手元に無く、試していません。

## 4. 回避

`MTLCompileOptions` を変えて、落ちる 4 個を試しました（`PROBE_MATH`・`PROBE_OPT`・`PROBE_PRESERVE_INVARIANCE`）。

| オプション | 結果 |
| --- | --- |
| 既定（`mathMode = .fast`） | 落ちる |
| **`mathMode = .safe`** | **4 個とも通る** |
| `mathMode = .relaxed` | 落ちる |
| `optimizationLevel = .size` | 落ちる |
| `preserveInvariance = true` | 落ちる |

fast math の最適化の中で落ちています。ただ、Flutter GPU のシェーダーは Impeller が MSL をコンパイルするので、アプリや flutter_scene からは
このオプションを変えられません。

## 5. 最小まで削り込む

シェーダー側で避ける書き方を探すため、落ちる MSL（`26678127` の `flutter_scene_standard_fragment`、8,757 行）を `scripts/reduce_msl.py` で
削り込みました。probe がコンパイルエラーではなくコンパイラの異常終了で失敗する限り、ブロックを消す・ブロックの中身だけ残す・変数の初期値を 0 に
する・文を消す・使わない宣言を消す、を何も減らなくなるまで繰り返します（10 並列、判定 1 回およそ 1 秒）。

```sh
python3 scripts/reduce_msl.py out/standard_26678127.metal out/reduced.metal --jobs 10
```

**1,528 行（`reduced/standard_26678127_reduced.metal`）で止まりました。** 判定は約 2 万 3 千回、2 時間ほどでした。残った 1,528 行のどのブロックを
消しても、どの文を消しても落ちなくなります。影のマップの読み取り 65 行、`if` 140 個、ループ 3 つが残り、特定の命令や書き方には絞れませんでした。
削り込んだ MSL も、M1 Max と `mathMode = .safe` では通ります。

単純な量の問題でもありませんでした。通る版（カスケード 2 段）と影を外した版に、関係のないテクスチャの読み取りや演算を最大 512 個、
末尾に足しても、`if` の中に最大 2,048 個入れて長く飛び越えさせても、落ちません。

量を確かめる道具は `scripts/pad_msl.py` です（末尾に足す `end-sample`・`end-alu`、`if` の中に入れる `if-end`・`if-start`）。

```sh
python3 scripts/pad_msl.py <通る版>.metal out/padded.metal 2048 if-start && probe/probe out/padded.metal | tail -1
```

### シェーダー側で避けられるか

flutter_scene の checkout（`26678127`）で `shaders/` を書き換え、`scripts/probe_standard.sh` を流しました。このスクリプトは checkout の今のファイルを
そのまま impellerc に渡すので、commit していない書き換えでも試せます（出力は `out/standard_<HEAD>.metal` に上書き）。書き換えはすべて
`material_shadow_sampling.glsl` の中です。

| 書き換え | MSL の行数 | 結果 |
| --- | ---: | --- |
| なし | 8,758 | 落ちる |
| 平行光源の影（`SampleShadow`）を空にする | 5,290 | **通る** |
| スポットライトの影（`SampleSpotShadow`）を空にする | 8,584 | 落ちる |
| 点光源の影（`SamplePointShadow`）を空にする | 8,514 | 落ちる |
| カスケードを 2 段にする（`_TRY_CASCADE(2)`・`(3)` を消す） | 7,046 | **通る** |
| カスケードを 3 段にする | 7,902 | 落ちる |
| `SampleCascade` の PCF の 17 回ループを消す | 7,702 | **通る** |
| PCSS（`filter_index` 2）の枝を消す | 7,766 | 落ちる |
| bilinear（`filter_index` 3）の枝を消す | 8,414 | 落ちる |
| 最後のカスケードの端のフェードを消す | 8,582 | 落ちる |
| PCF のループを 16 回・`break` なし／8 回／12 回／`sample_count` を上限に | 8,718 ほか | 落ちる |
| タップを Poisson だけ／Fixed だけ／`mix` をやめて選ぶ | 8,046〜8,814 | 落ちる |
| `ShadowTap` の clamp・回転を外す、`textureLod`、`step` にする | 8,750 ほか | 落ちる |
| 精度を highp にする（MSL は変わらない） | 8,758 | 落ちる |
| カスケードを先に選び、`SampleCascade` を最大 2 回だけ呼ぶ | 7,986 | 落ちる |
| 同じく 1 回だけ／`if` で囲まない／2 回をループで | 7,090〜7,952 | 落ちる |

通ったのは、平行光源の影を外す・カスケードを減らす・PCF を消す、の**機能を削るものだけ**でした。行数が少ないほど通るわけでもありません
（7,106 行の「1 回だけ」は落ち、7,702 行の「PCF なし」は通る）。

## 6. fast math を切ってアプリを動かす

Flutter GPU のシェーダーは Impeller が `newLibraryWithSource:options:` でコンパイルするので、アプリからは fast math を切れません。
そこで、起動時に差し込むライブラリ（`interpose/safemath.m`）で、そのときの `MTLCompileOptions` を `mathMode = .safe` に書き換えました。
同じライブラリが、1 秒あたりのコマンドバッファの数と GPU の実行時間の合計を 2 秒ごとに書き出します（Flutter の macOS は `CAMetalLayer` の
drawable を使わないので、フレーム数はコマンドバッファで見ます）。

```sh
clang -dynamiclib -fobjc-arc -framework Foundation -framework Metal -framework QuartzCore \
  interpose/safemath.m -o interpose/safemath.dylib
SAFEMATH=1 DYLD_INSERT_LIBRARIES=$PWD/interpose/safemath.dylib <app>/Contents/MacOS/<binary>
```

flutter_vrm の example（Seed-san、既定の画面、影あり）を、M4 Max・macOS 27.0.1 の release ビルドで動かしました。自分でビルドした
ad-hoc 署名のアプリなので差し込めます。3 つの条件を交互に 2 周、各 26 秒動かし、最初の 8 秒を除いた平均です。

| 条件 | 1 周目 GPU ms/秒 | 2 周目 GPU ms/秒 | 結果 |
| --- | ---: | ---: | --- |
| 0.23、fast math（既定） | 35.74 | 43.58 | 動く |
| 0.23、safe | 40.84 | 48.78 | 動く |
| master `cff220e`、safe | 51.94 | 52.42 | **動く**（既定の fast math では起動直後に落ちる） |

- **master でも fast math を切れば落ちずに動き、見た目も 0.23 と変わりませんでした。** コンパイルされた 13 個のライブラリがすべて safe で通っています
- どの条件もコマンドバッファは毎秒 600（120 Hz × 5）で、画面の更新は落ちていません
- 周ごとに全体が揺れました（画面共有のアプリが動いていた）。同じ周の中で比べると、0.23 で safe にした分の GPU 時間は +5.1 と +5.2 ms/秒
  （+14% と +12%）で、1 フレームあたり約 0.04 ms です。この場面は軽い（1 体、GPU は 4〜5% しか使っていない）ので、重い場面での差は測っていません
- master と 0.23 の差はシェーダーそのものが違うので、fast math の効果とは分けられません（master の fast math は落ちるため測れない）

## 7. アプリに組み込むとき

`DYLD_INSERT_LIBRARIES` は、SIP で守られたプログラム（`/usr/bin/env`、`nohup`、`#!/usr/bin/env bash` のスクリプト）を経由すると捨てられます。
`flutter run` もスクリプトなので、外から付けてもアプリに届きません。ビルドした実行ファイルを直接起動するときだけ効きます
（`nohup` を挟んで差し込めていなかったことに、ログに `[safemath]` が無いことで気づいた）。

`flutter run` のまま M4 の Mac で動かしたいときは、アプリ側で差し替えます。macOS の Runner（`MainFlutterWindow.swift` の `awakeFromNib` の先頭、
`FlutterViewController` を作る前）で、Metal デバイスのクラスの `newLibraryWithSource:options:error:` と
`newLibraryWithSource:options:completionHandler:` を `method_setImplementation` で包み、渡された `MTLCompileOptions` の写しを
`mathMode = .safe` にして元の実装へ渡します。普通の環境変数（`DYLD_` で始まらない）は SIP を通っても残るので、起動スクリプトが
CPU 名（`sysctl -n machdep.cpu.brand_string` が `Apple M4` を含む）を見て変数を付け、アプリは debug ビルドでその変数があるときだけ差し替える、
という分け方にすると、M1 では fast math のまま動きます。

## わかったこと

- flutter_scene の `master`（2026-09-16 の `1fa830b2` 以降）を使うアプリは、M4 Max の Mac で、影ありの標準の材質を描いた時点で落ちる。
  0.24.0 がこのまま出ると、0.24.0 でも同じになる
- 原因は Apple の M4 世代の Metal コンパイラ（fast math の最適化）で、flutter_scene のシェーダーに誤りがあるわけではない
- 平行光源の影（カスケード 4 段・PCF 17 回）は 0.23.0 から入っている。0.23 以降に点光源の影・多数のライトの扱い・平行投影のカメラなどが
  足されてシェーダーが育ち、`1fa830b2` で不具合を踏む側に入ったと読める。`1fa830b2` の変更に誤りがあるわけではない
- 回避は fast math を切ることで、アプリも動く（GPU 時間は 1 割あまり増える）。ただしそれは Impeller の設定になる。シェーダーの書き方で安定して避ける方法は見つからなかった
  （最小まで削っても 1,528 行が残り、どこを消しても落ちなくなる）

## 次にやること

- flutter_scene の本家へは [bdero/flutter_scene#436](https://github.com/bdero/flutter_scene/issues/436) で報告し、fast math の扱いを相談した（2026-09-30）
- Apple へは Feedback Assistant で報告した（FB24988821、2026-09-29。落ちる MSL・probe・27.0.1 のクラッシュログを添付し、30 日に削り込んだ MSL と safe math で動く結果を追記）
- M2・M3 で起きるかは、手元に機材が無く未確認
