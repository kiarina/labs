# MoGe-2 surface normals on Apple Silicon

[MoGe-2](https://github.com/microsoft/MoGe) ViT-S NormalをApple Silicon上で実行し、
CPUとMPSの推論時間、surface normal出力、同時に推定されるmetric 3D point mapとの
局所的な整合性を検証します。

## Purpose

本検証で明らかにしたい問いは次のとおりです。

- MoGe-2 ViT-S NormalをApple SiliconのCPUとMPSで実行できるか
- 同じFP32モデルと入力に対してMPSはCPUよりどの程度高速か
- 道路、卓上物体、群衆で面の向きや物体境界を目視上妥当に分離できるか
- 直接予測されたnormalと、同じ推論のmetric point mapから幾何的に計算したnormalは
  どの程度一致するか

速度には固定画像1枚を使い、3回のウォームアップ後に10回推論します。モデル読み込み、
画像読み込み、前処理、可視化、ファイル保存は推論時間に含めません。

## Model and conditions

MoGe-2は1枚のRGB画像からmetric 3D point map、metric depth、surface normal、validity
mask、カメラ内部パラメータを推定します。公式実装が公開するnormal対応モデルのうち、
最小のViT-S、35,103,656 parametersを使用します。

2026年7月16日時点の公式実装とHugging Face model revisionを次の値へ固定しました。

```text
repository: https://github.com/microsoft/MoGe
commit: 07444410f1e33f402353b99d6ccd26bd31e469e8
license: MIT

model: Ruicheng/moge-2-vits-normal/model.pt
revision: 679230677b4d282c6f304189a93e98e14f085902
size: 140,550,416 bytes
SHA-256: 79a16621928c2bf0ed04659218c55c01075e950507f40bb3332fb4c873d3e1dc
parameters: 35,103,656
```

入力はアスペクト比を維持して短辺384へ縮小し、RGBを`[0, 1]`へ正規化します。
MoGe-2の`resolution_level=5`、FP32、batch 1をCPUとMPSの両方で使用します。

直接予測されたnormalとpoint mapの整合性は、point mapの画像x・y方向の有限差分を
接ベクトルとし、その外積を単位長へ正規化して求めます。MoGe-2と同じOpenCV camera
coordinates（x right、y down、z forward）でカメラ側を向くよう符号を揃え、validity
mask内の画素単位角度差を計算します。これは正解normalに対する精度評価ではなく、同じ
モデルが出す2種類の表現の局所的な自己整合性です。

## Input

次の共有生成画像をリポジトリルートから相対参照します。

| image | original | model input | purpose | SHA-256 |
| --- | ---: | ---: | --- | --- |
| `tests/assets/jpg/street_scene_1774x887_287kb.jpg` | 1774x887 | 768x384 | benchmark、道路と建物 | `d5c865f452599311fbbfd0c132bb4f8b7ade4dd88f0c8ac14ce136490ea53a2e` |
| `tests/assets/jpg/objects_1536x1024_358kb.jpg` | 1536x1024 | 576x384 | 平面と曲面 | `aa973bb3f6283f30ec863cf21eeeca446d939715f6da168651c7c48fc7d935c5` |
| `tests/assets/jpg/many_face_1280x720_275kb.jpg` | 1280x720 | 683x384 | 群衆と複雑な遮蔽 | `af072b9b1dafc549226a96110c78ace8ae53a62c81e618382eb0faf0f35218a6` |
| `tests/assets/jpg/miineko1-1448x1086-221kb.jpg` | 1448x1086 | 768x576 | 3D動画、3Dキャラクター | `15f0da788e483cf33340843f2a5baa9fce3b6fa838908db8208187bc66b24a8d` |
| `tests/assets/jpg/miineko2-1448x1086-314kb.jpg` | 1448x1086 | 768x576 | 3D動画、アニメキャラクター | `88d49e58f4aa0f311613a53be6dbaedc5fea254f3588f390aa64edb48d122b42` |

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- Apple Silicon Mac
- 初回実行時にインターネット接続
- 3D動画を生成する場合はBlender 5.1.2とffmpeg

リポジトリルートから実行します。

```sh
mise -C 2026/07/16/moge2-surface-normal-apple-silicon run
```

道路画像からtexture付きGLBを作り、Blenderで左右に視点移動する動画まで生成する場合は
次を実行します。

```sh
mise -C 2026/07/16/moge2-surface-normal-apple-silicon run render-video
```

2枚の`miineko`画像についてGLBとBlender動画を生成する場合は次を実行します。

```sh
mise -C 2026/07/16/moge2-surface-normal-apple-silicon run render-miineko-videos
```

taskは最初に`mise run //:test-assets:download`を実行します。初回は固定revisionから
modelをダウンロードします。modelと次の出力は検証生成物なのでGit管理しません。

```text
output/results.json
output/qualitative_results.png
output/3d/street_scene_1774x887_287kb/mesh.glb
output/blender/moge2_street.blend
output/blender/moge2_street_camera_move.mp4
output/3d/miineko{1,2}-*/mesh.glb
output/blender/miineko{1,2}-*/camera_move.mp4
```

## Observed results

Apple M1 Max上で、同じFP32 checkpointをCPUとMPSの両方から追加patchなしで実行
できました。道路画像を3回ウォームアップした後、10回推論した結果です。

| backend | mean | median | min | max | std dev |
| --- | ---: | ---: | ---: | ---: | ---: |
| PyTorch CPU | 1,272.74 ms | 1,259.34 ms | 1,244.37 ms | 1,340.16 ms | 28.24 ms |
| PyTorch MPS | 211.58 ms | 212.13 ms | 208.75 ms | 214.68 ms | 1.88 ms |

中央値ではMPSはCPUより約5.94倍高速でした。MPSの約212 msはモデル推論だけで約4.71
FPSに相当します。同じ入力に対するCPUとMPSのnormal角度差は平均0.0063度、中央値
0度、最大0.0396度で、backendによる数値差は目視できない大きさでした。

normalとpoint map由来normalの画素単位角度差は次のとおりです。

| image | valid pixels | mean | median | p90 |
| --- | ---: | ---: | ---: | ---: |
| street | 90.80% | 30.75° | 18.69° | 78.55° |
| objects | 100.00% | 14.41° | 7.05° | 35.86° |
| crowd | 98.63% | 37.94° | 33.04° | 73.47° |

卓上画像では机、ノートPC、本の表裏がまとまった方向を示し、カップとボトルでは曲面に
沿ってnormalの色が連続的に変化しました。道路画像では路面、左右の建物、自動車、樹木を
異なる面方向として分離しました。空は無効領域になりました。群衆画像では人物の顔や肩の
丸み、前後に重なる人物の境界が残る一方、遠景の看板や細かな人物には不安定な縞も見られ
ました。これらは可視化の目視観測です。

直接予測normalとpoint map由来normalは、卓上画像の広い平面ではよく一致しました。
角度差は物体境界、細い構造、樹木、群衆、遠景で大きくなりました。有限差分はdepthが
不連続な境界の両側を結ぶため、この差を直接予測normalの誤差とは断定できません。

### Textured 3D mesh and Blender video

道路画像のmetric point mapを公式CLIの`--glb`で三角形meshへ変換し、元画像をUV
textureとして埋め込んだGLBを生成できました。`threshold=0.04`でdepth不連続部分を
edgeとして除去しています。Blender 5.1.2で読み込んだmeshは233,120 vertices、
449,292 triangles、bounding-box dimensionsは約30.75 x 114.21 x 21.15 mでした。
推定水平FoVは60.52度です。

Blenderでは推定カメラ原点から開始し、奥行き18 mの点を注視しながらx方向に±0.8 m、
後方へ0.25 m、上方へ0.15 m移動して原点へ戻る軌道を設定しました。元画像textureを
Principled BSDFのbase colorとemission colorに接続し、Eeveeで120 framesをレンダリング
しました。ffmpegでH.264、1280x720、30 FPS、4.0秒のMP4へ変換できました。

```text
GLB size: 13,342,320 bytes
GLB SHA-256: b13f1b81a2a5681064612373994ec9b666cb3cbdcd0966ab4561c54a4f1fd333

MP4 size: 980,733 bytes
MP4 SHA-256: fbaf9363d68f64ad530df83558b44534597209c63c70c8bbfcb80f5d80aedcab
codec: H.264, yuv420p
frames: 120
resolution: 1280x720
frame rate: 30 FPS
duration: 4.0 s
```

原点では元画像と同じ構図になり、左右へ動くと手前の自動車、道路、建物、人物の間に
視差が現れ、1枚の画像が実際に奥行きを持つmeshへ変換されたことを確認できました。
一方、空、樹木の隙間、物体境界はedge除去により穴になり、横から見ると建物や人物が
薄いsurfaceであることも見えました。単眼1枚から得た結果は自由に歩き回れる完全な3D
空間ではなく、元カメラ付近の小さな視点移動に適した2.5Dであることが観測されました。

#### Miineko images

同じ条件で2枚のアニメ調生成画像もGLB化し、Blenderで動画を生成できました。有効頂点の
depth中央値は1枚目が約7.32 m、2枚目が約7.01 mで、道路画像の約12.51 mより浅く推定
されました。そのため注視距離を10 m、左右移動を±0.5 mへ変更し、道路版と近い視角変化に
揃えました。

| image | vertices | triangles | FoV x/y | GLB size | MP4 size |
| --- | ---: | ---: | ---: | ---: | ---: |
| `miineko1` | 312,105 | 599,514 | 54.27° / 42.05° | 17,893,416 bytes | 1,262,371 bytes |
| `miineko2` | 325,649 | 621,216 | 60.30° / 47.08° | 18,731,304 bytes | 1,787,963 bytes |

```text
miineko1 GLB SHA-256: f0ec078be0dc2aad663729f85d4ca4f1ea2740a2cfeee4cc57aea1e4fc006a54
miineko1 MP4 SHA-256: 639365aac061166f7c13af6d784c38b01782cb39cbae8e11196fd6a6e7b781fc
miineko2 GLB SHA-256: c2790ba9b2e945b06beac8f88bf094feddabec65999f157c6bac42e6c524ab72
miineko2 MP4 SHA-256: 09424a71bb89bed7acf3d0bb5b8a046b714dd6d79ed81b41d16dd00e9ae735fd
```

1枚目ではピンクのキャラクターが背景の木、ベンチ、花壇より手前に配置され、カメラ移動で
明確な視差が出ました。頭部には緩やかな丸みが見える一方、耳、手、蝶ネクタイ、胴体は
カメラ側から見えるsurfaceだけで構成され、横から見ると薄さが分かりました。

2枚目でも人物、ベンチ、街灯、看板、背景の木々が異なる奥行きに分かれました。一方、人物の
髪、腕、脚は独立した完全な立体ではなく、輪郭に沿う薄いsurfaceとして見えました。両画像
とも空、木の葉、花、キャラクター輪郭のdepth edgeが多く、`threshold=0.04`でtriangleを
除去した黒い穴が道路画像より顕著でした。写実画像用の単眼geometry modelをアニメ調画像へ
適用できるものの、細線とstylized shapeの3D解釈には限界があることが観測されました。

### Failed attempt

最初はmetric depth画像のx・y画素勾配をそのまま`(-dz/dx, -dz/dy, 1)`としてnormalを
作り、直接予測normalと比較しました。しかし、この方法はカメラ内部パラメータと透視投影を
無視し、さらにカメラ座標の向きも逆だったため、中央値113–143度という不適切な差になり
ました。depthから復元済みのmetric point mapの接ベクトルを使い、外積をカメラ側へ向ける
方法に変更しました。

PyTorchのMoGe-2実装は後処理で`torch.autocast(..., dtype=torch.float32)`を呼ぶため、
CPUとMPSのどちらでもFP32 autocastは未対応というwarningが出ました。autocastは自動的に
無効化され、出力と計測は完了したため、公式実装へのpatchは行っていません。

Blender動画の最初の試行ではBlender 5.1.2に存在しないrender engine識別子
`BLENDER_EEVEE_NEXT`を指定して失敗しました。利用可能な`BLENDER_EEVEE`へ変更しました。
同じくcolor-management lookは`Medium High Contrast`ではなく
`AgX - Medium High Contrast`が必要でした。またBlender 5ではActionに`fcurves`属性が
直接公開されないため、補間の明示的な上書きを削除して既定のBezier補間を使用しました。

最初に±1.6 m移動して照明だけでPBR materialを描画した動画は、元画像より暗く、遮蔽部の
穴が大きく見えすぎました。最終版ではtextureをemission colorにも接続し、移動を±0.8 mへ
抑えました。これはmeshの推定結果を変える処理ではなく、観察しやすくする表示条件です。

### Verification environment

- machine: MacBook Pro (Apple M1 Max, 64 GB, arm64)
- OS: macOS 26.5.2 (25F84)
- Python: 3.12.10
- MoGe: commit `07444410f1e33f402353b99d6ccd26bd31e469e8`
- PyTorch: 2.13.0
- OpenCV: 5.0.0
- NumPy: 2.5.1
- Matplotlib: 3.11.0
- Blender: 5.1.2
- ffmpeg: 8.1.2

## Interpretation and limitations

MoGe-2 ViT-S NormalはM1 MaxのMPSで実行でき、同じFP32モデルのCPUより約5.94倍高速
でした。約212 msはリアルタイム動画向けとしては遅いものの、1回の推論でmetric depth、
3D point map、surface normalを同時に得られます。直接予測normalは、point mapを画素近傍の
有限差分へ変換したnormalより物体境界が滑らかで、独立したnormal headの利点が見えました。

本検証は正解normal・depthのない生成画像3枚、速度計測はそのうち1枚、短辺384、
`resolution_level=5`、FP32、batch 1、1台のM1 Maxに限られます。角度差はモデル自身の
2出力間の整合性であり、一般的なnormal推定精度を示しません。公式benchmark、実写、他の
resolution level、ViT-B/L、FP16、ONNX、Core ML、Apple Neural Engine、動画の時間的一貫性、
消費電力、ピークメモリは未確認です。

3D動画も道路画像1枚と1種類のカメラ軌道だけです。edge thresholdの違い、穴埋め、複数画像
の統合、物体裏面の生成、Gaussian splatting、NeRF、実写動画からの連続的な3D再構成は
未確認です。texture付きmeshは元視点付近では自然ですが、大きく横や後方へ移動できる完全な
3D sceneではありません。

前日のZipDepthはaffine-invariant inverse depthでカメラ内部パラメータを出さないため、
その出力から作るnormalとmetric point map由来normalを数値的に直接比較することは避けました。
