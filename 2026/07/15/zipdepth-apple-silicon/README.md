# ZipDepth on Apple Silicon

ZipDepth の軽量な単眼深度推定を Apple Silicon 上で動かし、PyTorch CPU、
PyTorch MPS、ONNX Runtime CPU の推論時間と出力の差を比較します。

## Purpose

本検証で明らかにしたい問いは次のとおりです。

- ZipDepth の公式 checkpoint を Apple Silicon の CPU と MPS で実行できるか
- モバイル向け checkpoint を ONNX へ変換し、ONNX Runtime CPU で実行できるか
- 同じ768x384入力に対する各backendの推論時間と数値出力はどの程度異なるか
- 屋外道路、卓上物体、群衆という異なる画像でも、目視上妥当な前後関係を出力するか

速度比較には固定画像1枚を使い、3回のウォームアップ後に10回推論します。定性的な
確認には3枚を使います。モデル読み込み、画像読み込み、前処理、可視化、ファイル保存は
推論時間に含めません。

## Model

[ZipDepth](https://github.com/fabiotosi92/ZipDepth) は ECCV 2026 で発表された
単眼相対深度推定モデルです。1枚のRGB画像から各画素の affine-invariant inverse
depth を推定します。値が大きい画素ほど手前ですが、メートル単位の距離ではありません。

公式発表では610万パラメータ、384x384入力で3.0 GMACsです。Depth Anything V2
Large が生成した擬似深度を用い、17 domain、約1,407万枚で知識蒸留されています。
本検証では2026年7月15日時点の公式実装を次のcommitへ固定しました。

```text
repository: https://github.com/fabiotosi92/ZipDepth
commit: a302e5437bc58f15c4efd41d3e8222bf24f7d470
license: MIT

standard checkpoint: zipdepth_base.pth
size: 27,298,978 bytes
SHA-256: a55910bb0b99c8c5e641cb9206e810b269690ad94e8a2ef08c827c4679391a65

NPU-compatible checkpoint: zipdepth_base_npu.pth
size: 27,295,474 bytes
SHA-256: 627c04fda584133ead4310074884a4a037061b4c01ba86e73e492ea30fab570d
```

通常版は `torch.nn.Unfold` を使う convex upsampling、NPU互換版はモバイル環境で
変換しやすい unfold-free upsampling を使います。PyTorch CPUとMPSには通常版、
ONNX Runtime CPUにはNPU互換版を使用します。NPU互換版自体のbackend差を分離するため、
同じモデルをPyTorch CPUでも計測します。

ONNXは速度比較に使う道路画像の前処理後shapeへ合わせ、PyTorch 2.13.0のexporterで
生成したopset 18、静的shapeのFP32モデルです。

```text
input:  image, float32, 1x3x384x768, RGB in [0, 1]
output: depth, float32, 1x1x384x768
provider: CPUExecutionProvider
```

## Input

次の共有生成画像をリポジトリルートから相対参照します。

| image | original | model input | purpose | SHA-256 |
| --- | ---: | ---: | --- | --- |
| `tests/assets/jpg/street_scene_1774x887_287kb.jpg` | 1774x887 | 768x384 | benchmark、屋外の奥行き | `d5c865f452599311fbbfd0c132bb4f8b7ade4dd88f0c8ac14ce136490ea53a2e` |
| `tests/assets/jpg/objects_1536x1024_358kb.jpg` | 1536x1024 | 576x384 | 卓上物体の境界 | `aa973bb3f6283f30ec863cf21eeeca446d939715f6da168651c7c48fc7d935c5` |
| `tests/assets/jpg/many_face_1280x720_275kb.jpg` | 1280x720 | 672x384 | 群衆と複雑な遮蔽 | `af072b9b1dafc549226a96110c78ace8ae53a62c81e618382eb0faf0f35218a6` |

公式実装と同様に、アスペクト比を維持して短辺を384へ縮小し、モデルのstrideに合わせて
縦横を最も近い32の倍数へ丸めます。前処理後のRGB画像と出力depthは同じ縦横サイズに
なるため、可視化では歪みのない画像を左右に並べます。32の倍数への丸めによる最大16画素
未満の差はあり得ますが、正方形への強制resizeは行いません。

## Requirements and run

- [mise](https://mise.jdx.dev/)
- [uv](https://docs.astral.sh/uv/)
- Apple Silicon Mac
- 初回実行時にインターネット接続

リポジトリルートから実行します。

```sh
mise -C 2026/07/15/zipdepth-apple-silicon run
```

taskは最初に `mise run //:test-assets:download` を実行します。初回は固定commitから
checkpointをダウンロードしてSHA-256を検証し、NPU互換モデルをONNXへ変換します。
モデル、ONNX、可視化結果は検証生成物なのでGit管理しません。

```text
output/backend_comparison.png
output/qualitative_results.png
```

## Observed results

Apple M1 Max上で通常版をPyTorch CPUとMPS、NPU互換版をPyTorch CPUとONNX Runtime
CPUから実行できました。道路画像を3回ウォームアップした後、10回推論した結果です。

| backend / model | mean | median | min | max | std dev |
| --- | ---: | ---: | ---: | ---: | ---: |
| PyTorch CPU / standard | 77.78 ms | 77.49 ms | 75.75 ms | 80.89 ms | 1.65 ms |
| PyTorch MPS / standard | 15.34 ms | 15.56 ms | 14.36 ms | 15.89 ms | 0.55 ms |
| PyTorch CPU / NPU-compatible | 101.49 ms | 100.47 ms | 97.44 ms | 109.55 ms | 3.26 ms |
| ONNX Runtime CPU / NPU-compatible | 47.08 ms | 47.17 ms | 46.54 ms | 47.46 ms | 0.33 ms |

中央値では、MPSは同じ通常版のPyTorch CPUより約4.98倍高速でした。ONNX Runtime
CPUは同じNPU互換版のPyTorch CPUより約2.13倍高速でした。一方、異なるモデルを使う
MPSとONNX Runtimeの直接比較では、MPSが約3.03倍高速でした。以前の384x384条件より
入力画素数が2倍になったため、各backendの推論時間も増えています。

inverse depthはaffine-invariantなので、候補出力 `x` に対して `a*x+b` が参照出力へ
最も近くなる `a` と `b` を最小二乗法で求めてからMAEとRMSEを計算しました。

| comparison | aligned MAE | aligned RMSE |
| --- | ---: | ---: |
| standard: PyTorch CPU vs MPS | 0.00000002 | 0.00000002 |
| NPU-compatible: PyTorch vs ONNX Runtime CPU | 0.00000001 | 0.00000002 |
| PyTorch CPU: standard vs NPU-compatible | 0.00044436 | 0.00086735 |

同じcheckpointのbackend間差はFP32の丸め誤差相当でした。通常版とNPU互換版は完全には
一致しませんが、道路画像の可視化では差を目視で判別できませんでした。

定性的には、道路画像では手前の路面と自動車が明るく、遠方の建物、空、道路の消失点が
暗くなりました。卓上画像では手前の机と本、奥のノートPC、窓外の背景が段階的に分かれ、
ボトルやカップの輪郭も残りました。群衆画像では前景の人物ほど明るくなり、人物間の
遮蔽に沿った境界も見られました。一方、遠方の細かな人物は個体ごとには分離されず、
滑らかな一領域として出力される部分があります。これらは目視観測であり、正解深度との
精度評価ではありません。

### Failed attempts

最初のONNX exportは `ModuleNotFoundError: No module named 'onnxscript'` で失敗しました。
PyTorch 2.13.0の新しいONNX exporterが `onnxscript` を必要とするため、依存関係へ明示的に
追加して解消しました。

公式例と同じopset 17を要求したところ、exporterは内部でopset 18を生成し、17への
version conversionに失敗しました。生成されたopset 18モデルはONNX checkerを通り、
ONNX Runtimeで実行できたため、本検証では実際に生成されたopset 18を採用しています。

### Verification environment

- machine: MacBook Pro (Apple M1 Max, 64 GB, arm64)
- OS: macOS 26.5.2 (25F84)
- Python: 3.12.10
- ZipDepth: commit `a302e5437bc58f15c4efd41d3e8222bf24f7d470`
- PyTorch: 2.13.0
- ONNX: 1.22.0
- ONNX Runtime: 1.27.0
- OpenCV: 5.0.0
- NumPy: 2.5.1
- Matplotlib: 3.11.0

## Interpretation and limitations

ZipDepthは追加patchなしでMPS上に載り、このM1 Maxと768x384入力では約15.34 ms、
約65 FPS相当のモデル推論ができました。公式CLIはdeviceとしてCUDAとCPUだけを
受け付けますが、これはモデルのMPS非互換を意味せず、lab側からPyTorch modelを直接
MPSへ移すことで動作しました。

ONNX Runtime CPUも約25 msで、同じNPU互換モデルのPyTorch CPUより速く、数値出力も
ほぼ一致しました。ただし通常版とNPU互換版でupsampling方式が異なるため、MPSとONNX
Runtimeの差をbackendだけの差とは断定できません。

本検証は正解depthのない生成画像3枚、速度計測はそのうち1枚、短辺384、FP32、batch 1、
1台のM1 Maxに限られます。メートル単位の距離精度、NYUv2などの公式benchmark、短辺384
以外の解像度、動画での時間的一貫性、Core ML、Apple Neural
Engine、量子化、消費電力、ピークメモリは未確認です。可視化は画像ごとに2–98 percentile
を0–1へ正規化しているため、異なる画像間で色を距離として直接比較できません。
