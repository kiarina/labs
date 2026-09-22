# ONNX Runtime Web from Flutter Web (D-FINE)

Flutter Web アプリから ONNX Runtime Web を呼び出し、ブラウザだけで ONNX モデルの推論が
動くかを確かめます。題材には、以前 Python の ONNX Runtime で動かした
[D-FINE 物体検出](../../../07/09/dfine-object-detection/README.md) を使います。
同じモデルと入力画像について、native の ONNX Runtime の出力と数値で突き合わせます。

## Purpose

本検証で明らかにしたい問いは次のとおりです。

- Flutter Web（dart2js ビルド）から、pub.dev のパッケージ経由で ONNX Runtime Web を
  呼び出し、41 MB の検出モデルをブラウザで推論できるか
- WebAssembly（CPU）と WebGPU のどちらで動くか。スレッド数と cross-origin isolation の
  有無で速度はどう変わるか
- ブラウザの出力は、同じ入力に対する native ONNX Runtime の出力とどの程度一致するか
- ブラウザ側の前処理（JPEG デコードと resize）は、Python 版の OpenCV とどの程度一致するか
- 前処理、tensor 作成、推論、出力読み出しの各段階にどの程度時間がかかるか

評価は固定画像 1 枚で行います。各条件で 3 回のウォームアップ後に 20 回計測し、各段階の
平均・最小・最大・標準偏差を記録します。数値の一致は、同じ入力 tensor に対する
`logits` と `pred_boxes` の最大絶対差、および検出結果（score 0.5 以上）の一致で判定します。


## Dependency advisories

`onnx` 1.20.0 に advisory が 16 件あります（high, medium, low。修正版は 1.22.0。2026-09-23 時点）。
`pyproject.toml` の完全固定なので lock からは上がりません。`onnx` は `reference.py` が
モデルを load / save するのに使っており、上げると native 側の参照出力を作り直すことになります。
**上げるかどうかは未決です。**

## Answer

- **使えます。** [`flutter_onnxruntime`](https://pub.dev/packages/flutter_onnxruntime)
  1.8.5 の web 実装は、`window.ort`（onnxruntime-web）を JS interop で呼び出します。
  `web/index.html` で onnxruntime-web を読み込めば、dart2js ビルドの Flutter Web アプリから
  D-FINE を推論でき、native と同じ 10 件を同じ bbox で検出しました
- **WebAssembly EP** は、どの bundle でもそのまま動きました。COOP/COEP ヘッダが無い
  静的配信では 1 スレッドに制限され、推論は約 760 ms でした。cross-origin isolation を
  有効にすると既定の 4 スレッドで約 218 ms、8 スレッドで約 138 ms まで短縮しました
- **WebGPU EP** は、読み込む bundle によって結果が分かれました。`ort.webgpu.min.js` を
  使うと、元のモデルのまま推論が約 42 ms、前後処理込みで約 80 ms になり、同じ PC の
  native CPU（約 120 ms）より速くなりました。`ort.min.js` と `ort.all.min.js` の WebGPU
  では、MaxPool の `ceil_mode` が未実装で推論に失敗しました
- **Flutter の `--wasm`（dart2wasm）ビルドでは動きませんでした。** セッション作成時に
  runtime type check で失敗します

## Architecture

```text
Flutter (Dart, dart2js)
  └─ flutter_onnxruntime 1.8.5 (web plugin: dart:js_interop)
       └─ window.ort  ← web/index.html が jsDelivr から読み込む onnxruntime-web 1.30.0
            ├─ WebAssembly EP (ort-wasm-simd-threaded*.wasm)
            └─ WebGPU EP
```

`web/index.html` は query parameter で bundle を切り替え、読み込み完了後に
`flutter_bootstrap.js` を起動します。モデルは `web/models/` に置き、
`OnnxRuntime().createSession('models/model.onnx')` で URL として渡すと、
onnxruntime-web が fetch します。

| query | 意味 |
| --- | --- |
| `ep=wasm` / `webgpu` / `webnn` | 使用する execution provider。`webgpu,wasm` のように並べると優先順のリストになる |
| `bundle=min` / `all` / `webgpu` | `ort.min.js`（既定）/ `ort.all.min.js` / `ort.webgpu.min.js` |
| `threads=N` | `ort.env.wasm.numThreads`。未指定なら onnxruntime-web の既定値 |
| `model=ceil0` | MaxPool の `ceil_mode` を 0 にしたモデルを使う（後述） |
| `warmup=N`, `iterations=N` | 計測回数。既定は 3 回と 20 回 |

`flutter_onnxruntime` には、session options の `intraOpNumThreads` があります。
一方、onnxruntime-web の WebAssembly EP では、スレッド数を `ort.env.wasm.numThreads` で
指定します。本検証は後者を `index.html` で設定しました。

## Model and input

```text
model: onnx-community/dfine_s_coco-ONNX, revision a3cf03147a9b86c78475139115c8ac142577352d
model.onnx SHA-256: cd8a49a945feda6d28c6304ae8ae85c2759ba1d78a5a83a22c5ce8db82ef7238 (41,535,197 bytes)
config.json SHA-256: 9338ef3863d6e95627d4ab06009fa85b1dd523b346b5c3595de2b08862136e99
opset: 16, nodes: 1,505
input:  pixel_values, float32, 1x3x640x640, RGB in [0, 1]
output: logits (1x300x80), pred_boxes (1x300x4)

image: tests/assets/jpg/objects_1536x1024_358kb.jpg
image SHA-256: aa973bb3f6283f30ec863cf21eeeca446d939715f6da168651c7c48fc7d935c5
score threshold: 0.5 (NMS なし)
```

前処理と後処理は、前回の lab と同じです。640x640 へ bilinear で resize し、RGB を 255 で割ります。
各 query について sigmoid の最大 class を選び、cxcywh の box を元画像の座標へ戻します。
ブラウザ側は `lib/dfine.dart` で次のように処理します。

- JPEG をブラウザのデコーダ（`ui.instantiateImageCodec`）でデコードする
- Q11 固定小数点の bilinear resize（OpenCV と同じ half-pixel の座標対応）を Dart で実装する

## Native reference

`reference.py` は、次の処理を行います。

- モデルをダウンロードし、SHA-256 を検証する
- Python の ONNX Runtime 1.30.0（CPUExecutionProvider）と OpenCV 5.0.0 で、同じ処理を実行する
- 次のファイルを `web/reference/` に書き出す。ブラウザはこれらを読み込み、自分の結果と比較する
  - デコード済み画素（`decoded_rgb.bin`）
  - 前処理後の tensor（`input.bin`）
  - 出力（`logits.bin`、`pred_boxes.bin`）

```text
Rank | Label       | Score | BBox xyxy
   1 | laptop      | 0.970 | (177, 116, 910, 690)
   2 | cup         | 0.965 | (870, 326, 1089, 520)
   3 | chair       | 0.962 | (5, 80, 543, 446)
   4 | bottle      | 0.950 | (1122, 74, 1273, 506)
   5 | cell phone  | 0.948 | (329, 700, 686, 918)
   6 | pottedplant | 0.938 | (1301, 2, 1535, 466)
   7 | book        | 0.915 | (930, 501, 1521, 838)
   8 | book        | 0.894 | (879, 614, 1519, 962)
   9 | diningtable | 0.836 | (0, 244, 1534, 1012)
  10 | vase        | 0.543 | (1456, 252, 1535, 465)

native 前処理 + 推論 + 後処理（3 回ウォームアップ後 20 回）:
mean 119.85 ms, min 114.33 ms, max 125.95 ms, stdev 3.22 ms
```

## Requirements and run

- [mise](https://mise.jdx.dev/)（Flutter 3.41.2 を `.mise.toml` で固定）
- [uv](https://docs.astral.sh/uv/)
- Chromium 系ブラウザ（WebGPU を使う場合は WebGPU 対応環境）
- インターネット接続（モデルと共有アセットの取得、jsDelivr からの onnxruntime-web 読み込み）

リポジトリルートから実行します。

```sh
# 共有アセット取得、モデル取得、native reference 作成、analyze、test、build
mise -C 2026/09/16/flutter-web-onnx-runtime run

# 通常の静的配信（cross-origin isolation なし）
mise -C 2026/09/16/flutter-web-onnx-runtime run serve

# COOP/COEP 付き（マルチスレッド wasm を有効にする）
mise -C 2026/09/16/flutter-web-onnx-runtime run serve --isolate --port 8001
```

ブラウザで、例えば次の URL を開きます。

```text
http://127.0.0.1:8000/?ep=wasm
http://127.0.0.1:8001/?ep=wasm&threads=8
http://127.0.0.1:8001/?ep=webgpu&bundle=webgpu
```

画面に検出結果の bbox、各段階の計測値、ログが表示されます。結果全体の JSON は
`window.dfineResult` と console（`DFINE_RESULT` で始まる行）に出力されます。
`web/models/`、`web/reference/`、`assets/`、`build/` は生成物のため、Git では管理しません。

## Observed results

MacBook Pro（Apple M1 Max、64 GB）で、Claude desktop app に組み込まれた Chromium
（Chrome/152.0.7977.76）の表示中のタブで計測しました。各行の数値は、3 回のウォームアップ後に
20 回計測した値です。

### Execution providers

`session_run` は `OrtSession.run` の所要時間です。`total` は、前処理、tensor 作成、
`session_run`、出力の読み出し、tensor の解放、後処理を合計した時間です。
JPEG デコードは、total に含みません。

| 配信 | bundle | ep | threads | 結果 | session_run mean (min–max, sd) | total mean |
| --- | --- | --- | ---: | --- | ---: | ---: |
| isolated | min | wasm | 1 | ok | 763.37 (756.75–786.89, 9.42) | 800.14 |
| isolated | min | wasm | 4（既定） | ok | 217.68 (215.76–220.35, 1.00) | 253.79 |
| isolated | min | wasm | 8 | ok | 137.76 (126.23–164.49, 10.09) | 173.73 |
| isolated | min | wasm | 10 | ok | 332.13 (286.80–401.19, 39.17) | 368.93 |
| isolated | webgpu | wasm | 4（既定） | ok | 217.49 (215.40–225.89, 2.32) | 254.05 |
| isolated | webgpu | webgpu | - | ok | **41.76** (40.30–43.75, 0.83) | **79.95** |
| isolated | min | webgpu | - | 推論で失敗 | - | - |
| isolated | min | webgpu, wasm | - | 推論で失敗 | - | - |
| isolated | all | webgpu | - | 推論で失敗 | - | - |
| isolated | min | webgpu（`model=ceil0`） | - | 推論で失敗 | - | - |
| isolated | all | webnn | - | session 作成で失敗 | - | - |
| 通常 | min | wasm | 1（強制） | ok | 764.38 (758.20–771.50, 4.08) | 811.84 |
| 通常 | webgpu | webgpu | - | ok | 44.79 (41.90–49.90, 2.07) | 93.97 |

「isolated」は COOP/COEP 付きで配信し、`crossOriginIsolated === true` だった条件です。
「通常」の 2 行は、前処理の丸め方を最終版へ変更する前のビルドで計測しました。推論の経路は
同じですが、そのビルドの前処理は約 22.8 ms（最終版は約 12 ms）だったため、total の値は
isolated の行と直接比較できません。通常配信の wasm は `crossOriginIsolated === false` となり、
onnxruntime-web は `numThreads` を 1 にしました。

失敗した条件のエラーは次のとおりです。

```text
ep=webgpu (bundle=min / all, ep=webgpu,wasm も同じ):
  Failed to run inference: Error: ceil_mode output-shape is computed, but ceil_mode kernel
  execution (padding) is not yet implemented in the WebGPU MaxPool kernel

ep=webgpu, model=ceil0 (bundle=min):
  [WebGPU] Kernel "[MatMul] /model/decoder/integral/MatMul" failed.
  Error: shared dimension does not match.

ep=webnn (bundle=all):
  no available backend found. ERR: [webnn] Error: WebNN is not supported in current environment
```

bundle ごとに読み込まれた runtime（Resource Timing で確認）:

- `ort.min.js`、`ort.all.min.js`: `ort-wasm-simd-threaded.jsep.mjs` と `.jsep.wasm`（28.3 MB）
- `ort.webgpu.min.js`: `ort-wasm-simd-threaded.asyncify.mjs` と `.asyncify.wasm`（26.8 MB）

### Phase breakdown

isolated 配信の代表的な 2 条件について、各段階の平均時間（ms）を示します。

| 段階 | wasm, 4 threads | webgpu (bundle=webgpu) |
| --- | ---: | ---: |
| preprocess（Dart の resize と正規化） | 11.79 | 13.86 |
| create_input_tensor（`OrtValue.fromList`） | 21.84 | 21.83 |
| session_run | 217.68 | 41.76 |
| read_outputs（`asFlattenedList` × 2） | 2.39 | 2.39 |
| postprocess | 0.06 | 0.07 |

- `create_input_tensor` が約 22 ms かかります。1,228,800 要素の `Float32List` を、
  プラグインが通常の JS Array を経由して `Float32Array.from` へ変換するためです
  （プラグインのソースを読んで確認）。WebGPU では、この変換時間が推論時間の半分に相当します
- セッション作成（モデルの fetch と runtime の初期化を含む）は 450–560 ms でした。
  ただし、一連の計測の最初の条件では 1588 ms でした
- WebGPU の初回推論は、この一連の計測では 113 ms でした。一方、この PC で最初に WebGPU を
  動かしたときは 2013 ms でした。2 回目以降に速くなったのは、ブラウザがシェーダーを
  キャッシュしたためと推測しますが、確認はしていません

### Runtime parity (same input tensor)

native が書き出した `input.bin` をブラウザでそのまま推論し、native の出力と比較しました。

| 条件 | logits max abs diff | pred_boxes max abs diff | 検出結果 |
| --- | ---: | ---: | --- |
| wasm, 1 thread | 2.36e-4 | 2.34e-5 | 10 件、ラベルと bbox が native と完全一致 |
| wasm, 4 threads | 2.28e-4 | 2.32e-5 | 同上 |
| wasm, 8 threads | 2.06e-4 | 2.04e-5 | 同上 |
| wasm, 10 threads | 2.45e-4 | 2.37e-5 | 同上 |
| webgpu (bundle=webgpu) | 2.35e-4 | 1.03e-5 | 同上 |

logits の差は 2e-4 程度でした。sigmoid 後の score では、小数第 3 位で最大 1 の差です。

### Preprocessing parity

ブラウザでデコードと前処理を行った tensor を、OpenCV の tensor と比べました。

| 比較 | 異なる値の数 | 最大差 |
| --- | ---: | ---: |
| JPEG デコード（ブラウザ vs `cv2.imread`、RGB 各 channel） | 866,985 / 4,718,592 (18.4%) | 1（8-bit） |
| resize（cv2 のデコード画素に Dart の resize を適用 vs `cv2.resize`） | 198,603 / 1,228,800 (16.2%) | 1/255 |
| 前処理全体（ブラウザ vs cv2） | 310,757 / 1,228,800 (25.3%) | 2/255 |

ブラウザで前処理した入力でも、10 件のラベルと bbox は native と完全に一致しました。
score の差は最大 0.004 です（vase: 0.539 vs 0.543）。

```text
laptop 0.970 · cup 0.965 · chair 0.962 · bottle 0.951 · cell phone 0.949 · pottedplant 0.938
book 0.916 · book 0.895 · diningtable 0.836 · vase 0.539   (bbox はすべて native と同一)
```

resize の差を詰めるため、Python で計算式の候補を比べました（`cv2.resize` と異なる画素数）。

- OpenCV の汎用実装にある 2 段階の丸め: 264,989
- 最後に 1 回だけ丸める Q11 固定小数点: 198,603
- 浮動小数点で計算して丸める方式: 217,437
- `INTER_LINEAR_EXACT`: 195,883

どれも完全には一致しませんでした。使った opencv-python 5.0.0.93 の build 情報には、
`Custom HAL: carotene, KleidiCV` と記載されています。arm64 では、resize がこの HAL の
実装へ切り替わっているためと推測します。Dart 側には、一様な画像を一様に保つ方式として、
最後に 1 回だけ丸める Q11 固定小数点を採用しました。

## Failed attempts and constraints

- **WebGPU の MaxPool `ceil_mode`**: D-FINE の backbone には、`ceil_mode=1` の MaxPool が
  1 つだけあります（`/model/backbone/model/embedder/pool/MaxPool`、kernel 2、stride 1、
  pads 0）。`ort.min.js` と `ort.all.min.js` の WebGPU 実装（JSEP）は、この属性で推論に
  失敗します。provider を `webgpu, wasm` と並べても、wasm へフォールバックしませんでした
- **`ceil_mode=0` のモデル**: stride 1、pads 0 では ceil と floor の出力サイズが同じなので、
  `reference.py` は `ceil_mode=0` にしたモデル（`model_ceil0.onnx`、SHA-256
  `5a77af5937ce4f74cb199c2f1ce1952ab1f69b3e4b6e7edb66f828b7f6038b59`）を書き出します。
  native CPU では、元のモデルとの出力差が 0 でした。しかし `ort.min.js` の WebGPU では、
  次に decoder の MatMul で失敗しました。`ort.webgpu.min.js` は元のモデルのまま動くため、
  WebGPU を使う場合はモデルを書き換えずに bundle を替える方が簡単です
- **WebNN**: この Chromium では WebNN が有効ではなく、backend がありませんでした
- **Flutter `--wasm` ビルド**: `flutter build web --wasm` は成功し、通常ビルドの
  wasm dry run も成功と表示しました。しかし実行すると、`createSession` が
  `Runtime type check failed` で失敗しました。プラグインのソースを読むと、Dart の `String` や
  `List` を `dynamic` のまま `JSObject.callMethod` の引数に渡しています。dart2js では
  Dart の値が JS の値そのものなので通りますが、dart2wasm では型チェックで失敗すると推測します。
  minify を外した profile ビルドでも詳細は表示されず、該当箇所の特定までは行っていません
- **非表示タブ**: ブラウザのペインが非表示になると、計測が進まなくなりました。
  非表示の状態で計測した値は、表に含めていません

## Interpretation and limitations

- Flutter Web で ONNX モデルを推論すること自体は、既存のパッケージで実現できます。
  ただし、onnxruntime-web のどの bundle を読み込むかで、使える EP とモデルの互換性が
  変わります。WebGPU を使うなら、まず `ort.webgpu.min.js` を試す価値があります
- WebAssembly のマルチスレッドには、COOP/COEP ヘッダによる cross-origin isolation が
  必要です。GitHub Pages のようにヘッダを設定できない静的ホスティングでは、wasm は
  1 スレッドになり、この PC で 1 回あたり約 0.8 秒かかりました。WebGPU は isolation が無くても
  約 45 ms で動きました。isolated 配信では、jsDelivr の CDN は
  `cross-origin-resource-policy: cross-origin` を返すため、そのまま読み込めました
- 10 スレッドの wasm は、4 スレッドより遅く、ばらつきも大きくなりました。M1 Max の
  高効率コア 2 基を含めたことや、ブラウザ内の他のスレッドとの競合が原因と推測しますが、
  確認はしていません。8 スレッドの値も標準偏差が 10 ms あり、安定していません
- 速度は、1 台の Mac の 1 つのブラウザ（Claude desktop app 組み込みの Chromium）で、
  各条件 1 回ずつ計測した結果です。Chrome 単体、Safari、Firefox、モバイル端末、
  他の GPU では確認していません
- Flutter の `--wasm` ビルドと、`flutter_onnxruntime` 以外のパッケージ
  （onnxruntime-web を自前の JS interop で直接呼ぶ方法を含む）は評価していません
- 入力 tensor の変換コスト（約 22 ms）は、プラグインの実装によるものです。
  `Float32List` を JS の `Float32Array` へ直接渡すように実装すれば、短縮できる見込みがあります
- 検出精度は、1 枚の生成画像で native と一致することだけを確認しました。一般的な精度は
  評価していません

## Verification environment

- machine: MacBook Pro (Apple M1 Max, 8 performance + 2 efficiency cores, 64 GB)
- OS: macOS 26.6.2 (25G83), arm64
- browser: Claude desktop app 2.110.0 内蔵 Chromium, `Chrome/152.0.7977.76`,
  `navigator.hardwareConcurrency = 10`
- Flutter 3.41.2 (stable), dart2js, CanvasKit renderer
- flutter_onnxruntime 1.8.5
- onnxruntime-web 1.30.0 (jsDelivr)
- native reference: Python 3.12.10, onnxruntime 1.30.0, opencv-python 5.0.0.93, numpy 2.5.1,
  onnx 1.20.0
