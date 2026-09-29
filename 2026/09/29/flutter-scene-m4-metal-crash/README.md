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

アプリは起動直後、最初のフレームを描くところで落ちます。

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

## わかったこと

- flutter_scene の `master`（2026-09-16 の `1fa830b2` 以降）を使うアプリは、M4 Max の Mac で、影ありの標準の材質を描いた時点で落ちる。
  0.24.0 がこのまま出ると、0.24.0 でも同じになる
- 原因は Apple の M4 世代の Metal コンパイラ（fast math の最適化）で、flutter_scene のシェーダーに誤りがあるわけではない
- 回避は fast math を切ることだが、それは Impeller の設定になる

## 次にやること

- flutter_scene の本家へ報告し、シェーダー側で避けられるかを相談する（再現に要るのはこの lab の probe と MSL だけで、VRM のファイルは要らない）
- Apple へは Feedback Assistant で報告した（FB24988821、2026-09-29。落ちる MSL・probe・27.0.1 のクラッシュログを添付）
- M2・M3 で起きるかは、手元に機材が無く未確認
