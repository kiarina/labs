# flutter_scene .fmat: custom attributes on skinned meshes and the default_black placeholder

[flutter_vrm](https://github.com/kiarina/flutter_vrm) の開発中、[flutter_scene](https://github.com/bdero/flutter_scene) の `.fmat` で
2 つの不具合に当たり、flutter_vrm 側では避けて進めました。本家へ報告する前に、flutter_vrm も VRM も使わない最小の再現を作り、
何が起きているのかを確かめます。

1. custom attribute（`.fmat` の `attributes` と `Geometry.setCustomAttribute`）を使うと、宣言した attribute の無いメッシュで
   不定値が読まれて殻が爆発し、VRoid のモデルに付けると 3D の描画全体が消えた
2. `.fmat` の sampler の `hint: default_black` が、iOS で白く読まれた

前提の lab: [flutter-scene-m4-metal-crash](../../29/flutter-scene-m4-metal-crash/README.md)（同じ master を使う。影ありの材質は M4 の Mac では
safe math が要る）。

## 条件

- flutter_scene は本家の `master` の `f706046e`（2026-09-30 時点の最新）
- Flutter 3.47.2（stable）
- macOS: Mac Studio M4 Max 128GB、macOS 27.0.1（debug ビルド）
- iOS: Simulator の iPhone 17 Pro（iOS 27.0）
- 骨入りのモデル: Khronos の [CesiumMan](https://github.com/KhronosGroup/glTF-Sample-Assets/tree/main/Models/CesiumMan)（CC BY 4.0）。
  VRM（Seed-san、VRoid の AvatarSample_A）でも同じ結果になることを確かめた

## ハーネス

`app/` は flutter_scene だけを使う Flutter アプリです。1 つのケースを 1 つの物体にして横に並べ、描いたフレームを読み戻して、
各物体の位置の色を出力します。目で見なくても結果が決まります。

```
[repro] C expected blue, got blue (rgb 33,120,241 at 400,268) ok
```

材質は 3 つです。

- `assets/materials/attr_probe.fmat`: custom attribute の `phase` を読み、緑（0）・青（1）・赤（それ以外）で塗る。頂点も法線方向へ `0.05 * phase` 押し出すので、
  不定値なら形が崩れる
- `assets/materials/hint_black.fmat` / `hint_white.fmat`: 何も設定していない sampler をそのまま出力する

| ケース | 物体 | 期待 |
| --- | --- | --- |
| A | 箱、attribute を設定、`attr_probe` | 青 |
| B | 箱、attribute を設定しない、`attr_probe` | 緑（MATERIALS.md は 0 が読まれると書く） |
| C | 骨入りのモデル、attribute を設定、`attr_probe` | 青 |
| D | 骨入りのモデル、attribute を設定しない、`attr_probe` | 緑 |
| H | 骨入りのモデル、attribute を設定、同じ geometry を組み込みの PBR でも描く（輪郭線の殻と本体のように 2 つの primitive） | 青 |
| I | 箱、attribute を設定、組み込みの PBR だけで描く | 橙 |
| J | 骨入りのモデル、attribute を設定、組み込みの PBR だけで描く | 橙 |
| E | 箱、`hint: default_black` | 黒 |
| F | 箱、`hint: default_white` | 白 |
| G | 箱、組み込みの PBR（基準） | 橙 |

macOS はビルドした 1 つのアプリを、ケースごとに環境変数で切り替えて起動します（`run_case.sh`。落ちたかはクラッシュレポートの有無で見る）。

```sh
cd app
curl -L -o models/CesiumMan.glb \
  https://raw.githubusercontent.com/KhronosGroup/glTF-Sample-Assets/main/Models/CesiumMan/glTF-Binary/CesiumMan.glb
flutter build macos --debug
./run_case.sh A B C D E F G H I J
# 影ありの光を足す。M4 の Mac では前提の lab の safe math の差し込みが要る
SHADOW=1 PRELOAD=<safemath.dylib> ./run_case.sh CG GH GI GJ
```

iOS は `--dart-define` で選びます。

```sh
flutter run -d <simulator> --dart-define=CASES=ACEFGIJ
```

## 結果

| ケース | macOS | iOS Simulator |
| --- | --- | --- |
| A 箱、設定あり | 青 ok | 青 ok |
| B 箱、設定なし | **アプリが落ちる** | **アプリが落ちる**（同じログ） |
| C 骨入り、設定あり | 青 ok | 青 ok |
| D 骨入り、設定なし | **赤（不定値）で、形が画面いっぱいに崩れる** | 同じ |
| H 骨入り、設定あり + 同じ geometry を PBR でも | 青 ok | — |
| I 箱、設定あり、PBR だけ | **描かれない** | **描かれない** |
| J 骨入り、設定あり、PBR だけ | **描かれない** | **描かれない** |
| E `default_black` | **白** | **白** |
| F `default_white` | 白 ok | 白 ok |
| G 基準 | 橙 ok | 橙 ok |

影ありの光を足すと（macOS、safe math）:

| 組み合わせ | 結果 |
| --- | --- |
| C + G | どちらも ok |
| I + G | I は描かれない、G は ok（影なしと同じ） |
| **H + G** | **どちらも描かれない。3D の描画全体が消える。ログに何も出ない** |
| **J + G** | **どちらも描かれない** |

H と J は、CesiumMan でも Seed-san でも AvatarSample_A でも同じでした。VRoid のモデルに特有ではありません。

## 何が起きているか

### 1. custom attribute

`.fmat` が宣言する attribute と、geometry が持つ attribute の組が合わないと、4 通りの壊れ方をします。

**材質が宣言し、geometry が持たない（B、D）**

- 骨なし（B）: geometry の頂点レイアウトは組み込みのもの（`kUnskinnedInstancedLayout`）で、`phase` を含まない。Metal がパイプラインを拒み
  （`Vertex attribute phase(0) is missing from the vertex descriptor`）、その後の `RenderPass::Draw` で segfault する
  （`impeller::PipelineDescriptor::GetHash()`）。`tryResolvePipeline` が拾えないのは、Flutter GPU の `createRenderPipeline` が例外を投げず、
  描くときに初めて落ちるから
- 骨入り（D）: `SkinnedGeometry.defaultVertexLayout` は custom attribute が無いと `null` を返し、レイアウトはシェーダーの reflection から
  作られる。バインドされていない `phase` をどこから読んでいるかは確かめていない（reflection のレイアウトが骨入りの頂点のバッファの中を指していると見ている）。
  いずれにせよ MATERIALS.md の「0 が読まれる」にならない

flutter_vrm で輪郭線の殻が爆発したのは D です（輪郭線の材質だけが attribute を宣言し、太さのテクスチャを持たないメッシュには設定していなかった）。

**geometry が持ち、材質が宣言しない（I、J、H）**

- geometry に custom attribute を付けると、その geometry の頂点レイアウトに attribute のバッファが加わる（`customAttributeBuffers`）。
  attribute を宣言しない材質（組み込みの PBR など）のシェーダーでは、`VertexAttribute name 'phase' does not match any input declared by the bound vertex shader`
  でパイプラインが作れない
- 色のパスは `tryResolvePipeline` でその描画を飛ばす（I、J が描かれない。ログは出る）
- 影のパスは `resolvePipeline`（例外を投げるほう）を使う。骨入りの geometry は影のパスでも位置だけのレイアウトでなく自分の全レイアウトを使うので、
  ここで例外になり、**そのフレームの 3D の描画全体が消える**（H、J + 影）。例外はどこかで握りつぶされ、ログに出ない

flutter_vrm で VRoid のモデルの描画全体が消えたのはこれです（本体は MToon、輪郭線の殻だけが attribute を宣言し、同じ geometry に付けていた。
example は影ありの光を使う）。

`patches/shadow-try-resolve-pipeline.diff`（影のパスも `tryResolvePipeline` にして、作れない描画を飛ばす）を当てると、H + G + 影は両方 ok に戻りました。
J が描かれないのは変わりません（色のパスで飛ばされる）。これは症状を小さくするだけで、根は「geometry の attribute のバッファを、材質が宣言していなくても
レイアウトに入れる」ことにあります。

### 2. `default_black`

`MaterialParameters._placeholder`（`lib/src/material/material_parameters.dart`）が、`default_normal` 以外のヒントをすべて白の placeholder に
対応させています。コメントに「black/transparent の placeholder は今後追加」とあります。黒の placeholder（`Material.getBlackPlaceholderTexture`）は
既にあるのに使われていません。

iOS に特有ではありませんでした。macOS でも白です。flutter_vrm の作業で「macOS では黒」と見えた理由は確かめていません
（このコードは 2026-05-26 の `a4f5f39d` から変わっていない）。

## 回避

- custom attribute: 使わない。flutter_vrm は、輪郭線の太さのテクスチャを fragment で discard するマスクにした
- `default_black`: 頼らない。テクスチャが無いときは係数を 0 にする（flutter_vrm は matcap と shading shift）。または黒の 1×1 テクスチャを自分で設定する

## 本家の修正

- `default_black`: [bdero/flutter_scene#441](https://github.com/bdero/flutter_scene/pull/441)（黒と透明の仮テクスチャを使う）が取り込まれた（2026-09-30、`85f47359`）
- custom attribute: [bdero/flutter_scene#443](https://github.com/bdero/flutter_scene/pull/443)（描画ごとの頂点レイアウトを geometry と材質の両方から決める。
  材質が宣言して geometry に無い attribute は 0 を読み、材質が宣言しない attribute は無視する。影のパスは作れない描画を飛ばす）。
  その head（`ff63abbb`）で、macOS（M4 Max、fast math のまま）と iOS Simulator の A〜J が全部 `ok`、影ありの C+G・G+H・G+I・G+J も全部 `ok`。
  骨入りの D・H・J は AvatarSample_A と Seed-san でも `ok`（2026-09-30）
