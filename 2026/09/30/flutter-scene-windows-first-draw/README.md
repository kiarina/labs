# flutter_scene on Windows: the first draw of a skinned mesh stalls for seconds

[flutter_vrm](https://github.com/kiarina/flutter_vrm) の example を Windows で動かすと、VRM を読み込んで初めて描くフレームで
窓が 23〜26 秒止まりました（2026-09-29）。flutter_vrm を使わずに flutter_scene だけで再現し、何に時間がかかっているのかを切り分けます。

前提の lab: [flutter-scene-3d-garden](../../28/flutter-scene-3d-garden/README.md)（flutter_scene 0.23.0 の Windows で初回 6〜11 秒）、
[flutter-scene-m4-metal-crash](../../29/flutter-scene-m4-metal-crash/README.md)（本家の #438 で直った、照明の処理の重複）。

## 条件

- Windows PC: Core i9-12900K・GeForce RTX 3080 Ti・64 GB、Windows 11。Flutter 3.47.2（stable）、release ビルド。
  Impeller は OpenGL ES（ANGLE、D3D11）で動く
- flutter_scene は本家の `master`。`aae39f9`（2026-09-30、#438 を含む）と `cff220e`（2026-09-28、#438 の前）
- 骨入りのモデル: Khronos の [CesiumMan](https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/CesiumMan)（CC BY 4.0）
- 比べる相手: Mac Studio M4 Max 128GB（macOS 27.0.1、Metal）

## ハーネス

`app/` は flutter_scene だけを使う Flutter アプリです。床（PBR の箱）を描いたあと、1 秒おきに物体を 1 つずつ足し、その物体を初めて描くフレームまでの
時間と、その間のフレームの UI スレッド（build）とラスタースレッドの最長の時間を、ファイルに書きます。

- `unlit`: 箱、`UnlitMaterial`
- `pbr`: 箱、`PhysicallyBasedMaterial`
- `skinned`: CesiumMan（glTF の PBR の材質のまま）
- `skinned_unlit`: CesiumMan の材質を `UnlitMaterial` に替えたもの

`run_windows.sh` がアプリを Windows へ送り、release でビルドし、対話タスクとして起動して結果を回収します
（Windows のアプリは GUI サブシステムなので stdout を取れず、ssh のセッションからは窓を出せない）。

```sh
cd app && curl -L -o models/CesiumMan.glb \
  https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/CesiumMan/glTF-Binary/CesiumMan.glb && cd ..
WIN_HOST=user@windows-pc ./run_windows.sh                 # app/pubspec.yaml の commit
WIN_HOST=user@windows-pc ./run_windows.sh <commit>        # 別の commit
SHADOW=0 STEPS=skinned_unlit,skinned WIN_HOST=... ./run_windows.sh
RUNS=2 WIN_HOST=... ./run_windows.sh                      # 同じビルドを 2 回起動する
```

## 結果

初めて描くフレームまでの時間（秒）。影は影を落とす平行光源。

| | 床（最初の PBR） | unlit の箱 | 2 つ目の PBR の箱 | 骨入り（PBR） | 骨入り 2 体目 |
| --- | --- | --- | --- | --- | --- |
| `cff220e`（#438 の前）、影あり | **25.7** | 0.19 | 0.01 | **24.2** | 0.00 |
| `aae39f9`（#438 の後）、影あり | **8.0〜8.5** | 0.18 | 0.01 | **7.5** | 0.01 |
| `aae39f9`、影なし | 3.6 | 0.18 | 0.01 | 3.0 | 0.00 |
| macOS（M4 Max）、`aae39f9`、影あり | 0.66 | 0.13 | 0.03 | 0.11 | 0.01 |

- 止まっている時間は、ほぼすべて UI スレッドです（その間のフレームの build が 7,460 ms、raster は数 ms）
- `skinned_unlit`（骨入り + unlit）は 0.18 秒。骨入りでも、材質が軽ければすぐ描ける
- 床で PBR の材質を一度描いていても、骨入りの PBR は改めて 3.0 秒（影ありは 7.5 秒）かかる。2 つ目の PBR の箱（床と同じ頂点シェーダー）はすぐ描ける
- 同じビルドを続けて 2 回起動しても、2 回目も同じだけかかる（床 8.0 → 7.95 秒、骨入り 7.6 → 7.5 秒）。起動をまたいで残るものは無い
- flutter_scene のパイプラインの作成の時間を測るログ（`FLUTTER_SCENE_PROFILE`）には、8 ms を超えるものが出ない。時間は `createRenderPipeline` の中ではなく、
  その後の描画で使われる

## どこで時間を使っているか

Windows Performance Toolkit の xperf で、1 回の実行（影あり、`aae39f9`。床 8.3 秒 + 骨入り 7.7 秒止まった）の CPU のサンプルを DLL ごとに数えました。

```bat
xperf -on PROC_THREAD+LOADER+PROFILE -stackwalk Profile
rem ここでアプリを起動し、終わるのを待つ
xperf -d trace.etl
xperf -i trace.etl -o detail.txt -a profile -detail
```

アプリのプロセスの CPU 時間 20.7 秒のうち:

| DLL | 時間 | 割合 |
| --- | --- | --- |
| `D3DCompiler_47.dll` | **15.8 秒** | **76%** |
| `flutter_windows.dll`（Flutter と ANGLE） | 1.3 秒 | 6% |
| `nvwgf2umx.dll`（NVIDIA のドライバー） | 0.6 秒 | 3% |
| その他 | 3.0 秒 | 15% |

止まった時間の合計（約 16 秒）が、ほぼそのまま Microsoft の HLSL コンパイラ（`D3DCompiler_47.dll`）の中で使われています。ANGLE は OpenGL ES の
シェーダーを HLSL に書き換えて、このコンパイラでコンパイルします。GPU の速さの差ではなく、シェーダーのコンパイルの経路の差です。macOS は Metal の
コンパイラが MSL を直接コンパイルします。

## 見立て

- **25 秒のほとんどは、照明の処理の重複（本家 #436・#438）でした。** #438 で影ありの PBR の fragment シェーダーが小さくなり、25 秒が 7.5 秒になりました
- 残る数秒は、**PBR の fragment シェーダーのコンパイルを、頂点シェーダーとの組ごとにやり直している**ように見えます。骨なしと骨入り（と、影を描くための
  組）で、それぞれ払っています。時間を使っているのは `D3DCompiler_47.dll` です（上の表）。ANGLE の D3D11 は、プログラムをリンクするときに
  頂点と fragment の組に合わせて HLSL を作ってコンパイルするので、組ごとにやり直しているのだと思います（組ごとかどうかは、DLL の内訳からは確かめていない）
- 起動のたびに同じだけかかるので、プログラムのキャッシュ（EGL の blob cache など）も使われていないようです
- macOS（Metal）では同じことが 0.1 秒で終わります

## 回避

- `Scene.warmUp`（`SceneView(warmUp: true)`）で、描く前にパイプラインを作っておく。止まる時間は減らないが、読み込み画面の間に寄せられる。
  骨入りのモデルを含めてシーンを組んでから呼ぶ
- 影を切ると半分以下になる（7.5 → 3.0 秒）
