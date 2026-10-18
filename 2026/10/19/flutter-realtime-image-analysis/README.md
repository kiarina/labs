# Real-time camera frame analysis in Flutter on macOS, Windows, Android, iOS and web

カメラのコマを端末の中でリアルタイムに解析し、**顔・物・場面を entity として追いながら、その埋め込みを保持できるか**を確かめます。
解析の中身は、Python の [kiarina-python](https://github.com/kiarina/kiarina-python)（commit `9d483457`、kiarina-agi-image 2.28.0）の
画像の処理を Dart に移したものです。埋め込みは、kiarina-agi-data の `Embedding` と同じ形（`kind`・`space_id`・`vector`・`metadata`）で持ちます。
後で長期記憶（存在記憶）に永続化し、ベクター検索で entity を特定するための材料です。

| 処理 | モデル | kiarina の実行 | Dart から使う道 |
| --- | --- | --- | --- |
| 顔の検出（枠と 5 点の目印） | YuNet 2023mar | OpenCV DNN（int8 の ONNX） | ONNX Runtime（float32 に戻した ONNX。下の「YuNet」）。web は onnxruntime-web |
| 顔の埋め込み（128 次元） | SFace 2021dec | OpenCV DNN | ONNX Runtime |
| 物の検出（COCO の 80 種） | D-FINE s | ONNX Runtime | ONNX Runtime |
| 物の切り抜き・場面（コマ全体）の埋め込み（768 次元） | SigLIP2 base patch16 224（int8、画像側） | ONNX Runtime | ONNX Runtime |

マイクの音の解析は、前の lab [flutter-realtime-audio-analysis](../../18/flutter-realtime-audio-analysis/README.md) で同じ形に確かめました。
画像の各モデルの単体の検証は [YuNet](../../../07/08/yunet-face-detection/README.md)・[D-FINE](../../../07/09/dfine-object-detection/README.md)・
[SFace](../../../07/10/sface-face-embedding/README.md) の lab にあります。

## Purpose

1. kiarina と同じモデルを、Dart から 5 つのプラットフォーム（macOS・Windows・Android・iOS・web）で動かせるか（kiarina が OpenCV で動かしている YuNet・SFace も ONNX Runtime で）
2. Dart に移した前処理と、各プラットフォームの推論が、Python と同じ結果を出すか
3. 顔・物・場面を entity として追い、一度いなくなったものが戻ってきたときに同じ entity と分かるか。そのためのしきい値をどこに置くか
4. カメラの速さ（毎秒 2〜8 コマ）に追いつくか。どこが重いか
5. 埋め込みを entity ごとに保持して、メモリが増え続けないか

## Answer

- **4 つのモデルとも、Dart から 5 つのプラットフォームすべてで動きました**（macOS・Windows・Android は Pixel 6・iOS は iPad Air 4・web は Chrome）。 kiarina の YuNet は OpenCV 専用の量子化の形で ONNX Runtime では読めないので、
  重みを同じ値の float32 に戻した ONNX を作りました（`tools/convert_yunet.py`）。ONNX Runtime での結果は OpenCV と同じでした（顔の数は全コマで一致、座標の差 6e-5 px 以下）
- **前処理は、Python の参照の経路とビット単位で一致しました。** YuNet の入力 52 コマ、D-FINE の入力 52 コマ、SigLIP2 の入力（コマ 52 枚・物の切り抜き 272 個）、
  整列した顔 29 枚のすべてで sha256 が同じです（`packages/image_analysis/test/python_parity_test.dart`）
- **顔と物の検出、顔の埋め込みは、5 つのプラットフォームとも Python とほぼ同じ値です。** 顔の座標・物の枠の差は 7e-7 以下、顔の数・物の数とラベルは全コマで一致、
  顔の埋め込みのコサイン類似度は 0.9999997 以上
- **SigLIP2（int8）の埋め込みは、ONNX Runtime の版で動きます。** 同じ入力のバイトでも、アプリの ONNX Runtime 1.28（web は onnxruntime-web 1.30）と Python の 1.31 では
  コサイン類似度が最小 0.975〜0.985 まで下がりました（arm64 の macOS・Android・iOS は 3 つとも同じ値）。Python の 1.28 でも同じ値になり、スレッド数では変わらないので、版の違いです。
  入力に ±1 の濃さのノイズを足すだけでも 0.979 まで下がる（中央値 0.987）、もともと揺れやすいモデルです。永続化した埋め込みを後で比べるときは、この幅を見込む必要があります
- **kiarina の経路（OpenCV）とも、この揺れの範囲で一致しました。** arm64 の OpenCV 5.0 は縮小と warpAffine を KleidiCV で行い、OpenCV 本来の計算と ±1 ずれます。
  Dart は縮小を OpenCV 本来の固定小数点で、顔の整列を倍精度の双線形で書きました（後者は KleidiCV と 99.96% のバイトで一致し、差は最大 1）。
  そのため kiarina とは、顔は同じ値（コサイン 0.999999 以上）、SigLIP2 はコサイン 0.983 以上、D-FINE は 52 コマ中 2 コマでしきい値の際の 1 個の有無が違いました
- **人と場面は、いなくなって戻ってきたときに同じ entity と分かりました**（5 つのプラットフォームすべて。取りこぼしたコマがある場合も）。会話の 2 人 → ドア → 群衆の写真 → コップ → 同じ会話の後半、とつないだ 24.5 秒の流れで、
  後半の人は前半の f1、後半の場面は前半の s1 になりました。ただし、最初に置いた SFace の推奨しきい値 0.363 では、群衆の写真の別人を f1 と取り違えました（0.374）。
  **見えている顔を追い続けるときは 0.363、いなくなった人と照らすときは 0.5** に分けると、取り違えが消えました（下の「しきい値」）
- **物は、埋め込みだけでは同じ物と決められません。** 同じラベルの別の物同士でも SigLIP2 のコサインが 0.94 前後まで似るので、物はラベルと枠の重なりで追い、
  いなくなった物を照らすのは 0.95 以上のときだけの「手がかり」にしました。繰り返し同じ映像を流すと、物の entity は回ごとに作り直されて増えます（10 回で 353。顔は 3、場面は 4 のまま）
- **macOS（M1 Max）は毎秒 2 コマに余裕で追いつきます。** 1 コマの処理の中央値は 206 ms、物の検出もする回で 421 ms（p90）。取りこぼしは毎秒 2 コマで 0、4 コマで 49 中 3、8 コマで 49 中 11
- **iPad Air 4 は毎秒 2 コマで 49 中 5、1 コマで 1 の取りこぼし。Pixel 6 と web（Chrome、M1 Max）は毎秒 2 コマに追いつかず（49 中 19）、毎秒 1 コマで 4 になりました。**
  Pixel 6 は D-FINE が 1 回 412 ms、web は SigLIP2 が 1 回 252 ms で、それぞれいちばん重い段です。Pixel 6 はスレッドを 4 にしても変わりませんでした
- **Windows（Core i9-12900K）は、ONNX Runtime のスレッド数を絞らないと追いつきません。** 既定（論理コア 24 すべて）では 1 コマ 834 ms で 49 中 20 を取りこぼし、
  8 スレッドにすると 188 ms で取りこぼし 0 になりました（P コアと E コアの混ざった CPU で、全スレッドを使うと遅くなると解釈しています。原因の切り分けはしていません）
- **保持する埋め込みは小さく、メモリは増え続けませんでした。** 24.5 秒の流れで entity 72 個・埋め込み 66 個（159 KB）、10 回繰り返して 490 コマで 138 個（380 KB）。
  プロセスのメモリ（RSS）は 671〜709 MB で横ばいでした（モデル 4 つを含む）

## Results

### モデルが Python と同じ値を出すか（parity）

アプリ（flutter_onnxruntime 1.9.0 = ONNX Runtime 1.28、web は onnxruntime-web 1.30.0 の wasm）と、Python の参照の経路（ONNX Runtime 1.31、macOS arm64）を、同じ入力で比べました（`results/*-parity.json`）。

| | macOS | Windows | Android | iOS | web |
| --- | --- | --- | --- | --- | --- |
| 顔の数・物の数が違うコマ、ラベルの違い | 0、0、0 | 0、0、0 | 0、0、0 | 0、0、0 | 0、0、0 |
| 顔の枠・目印の差（正規化した座標） | 5.9e-7 | 5.9e-7 | 5.9e-7 | 5.9e-7 | 5.9e-7 |
| 顔の埋め込みのコサイン（最小） | 0.99999994 | 0.9999994 | 0.99999994 | 0.99999994 | 0.9999998 |
| 物の枠の差、スコアの差 | 5.9e-7、7.3e-6 | 6.4e-7、7.3e-6 | 5.7e-7、1.2e-5 | 5.8e-7、5.4e-6 | 5.8e-7、1.2e-5 |
| 物の切り抜きの埋め込みのコサイン（最小 / 中央値） | 0.9775 / 0.9965 | 0.9800 / 0.9954 | 0.9775 / 0.9965 | 0.9775 / 0.9965 | 0.9846 / 0.9955 |
| 場面の埋め込みのコサイン（最小 / 中央値） | 0.9800 / 0.9919 | 0.9751 / 0.9910 | 0.9800 / 0.9919 | 0.9800 / 0.9919 | 0.9782 / 0.9914 |

Python の参照の経路と kiarina の経路の差（`results/python-ref-vs-kiarina.json`、`tools/summarize_fixtures.py`）:

- 顔: 数は全コマで一致、座標の差 1e-6、埋め込みのコサイン 0.999999 以上
- 物: 52 コマ中 2 コマで数が 1 違う（しきい値 0.5 の際）、数の同じコマで枠の差は最大 0.063、ラベルの違い 2
- SigLIP2 のコサイン: 物の切り抜き 0.983 以上（中央値 0.995）、場面 0.986 以上（中央値 1.000）

### 1 回の推論の速さ（parity、中央値）

| | macOS（M1 Max） | Windows（i9-12900K、既定のスレッド） | Android（Pixel 6） | iOS（iPad Air 4） | web（Chrome 155、M1 Max） |
| --- | --- | --- | --- | --- | --- |
| YuNet（768x512 のコマ） | 23.8 ms | 27.2 ms | 91.7 ms | 29.9 ms | 13.0 ms |
| SFace（1 顔） | 9.7 ms | 9.6 ms | 31.0 ms | 18.4 ms | 12.6 ms |
| D-FINE | 135 ms | 265 ms | 412 ms | 287 ms | 233 ms |
| SigLIP2（コマ全体 / 切り抜き 1 個） | 43.9 / 43.3 ms | 36.6 / 36.8 ms | 183 / 175 ms | 105 / 103 ms | 252 / 252 ms |
| 4 つのモデルを開く（ダウンロード済みのファイルから） | 0.3 s | 1.2 s | 0.9 s | 0.4 s | 6.4 s（このほかに、開くたびのダウンロードが約 12 s） |

### カメラの速さで流す（replay）

768x512 の「カメラ」を毎秒 2 コマで 24.5 秒（49 コマ）。解析が前のコマに追いついていないときに来たコマは、最新の 1 枚だけ残して捨てます（`results/*-replay*.json`）。

| | 取りこぼし | 1 コマの処理（中央値 / p90） | 場面 | 顔 | 物の検出 | 物の埋め込み |
| --- | --- | --- | --- | --- | --- | --- |
| macOS、毎秒 2 コマ | 0 / 49 | 206 / 421 ms | 61 ms | 20 ms | 135 ms | 87 ms |
| macOS、毎秒 4 コマ | 3 / 49 | | | | | |
| macOS、毎秒 8 コマ | 11 / 49 | | | | | |
| Windows、毎秒 2 コマ、既定のスレッド | 20 / 49 | 834 / 1480 ms | 186 ms | 26 ms | 528 ms | 287 ms |
| Windows、毎秒 2 コマ、8 スレッド | 0 / 49 | 188 ms | 41 ms | 24 ms | 132 ms | 47 ms |
| Android（Pixel 6）、毎秒 2 コマ | 19 / 49 | 668 / 1958 ms | 154 ms | 95 ms | 415 ms | 142 ms |
| Android、毎秒 2 コマ、4 スレッド | 20 / 49 | 727 / 1917 ms | 154 ms | 99 ms | 428 ms | 144 ms |
| Android、毎秒 1 コマ | 4 / 49 | 769 / 1405 ms | 176 ms | 115 ms | 433 ms | |
| iOS（iPad Air 4）、毎秒 2 コマ | 5 / 49 | 420 / 910 ms | 101 ms | 24 ms | 269 ms | 201 ms |
| iOS、毎秒 1 コマ | 1 / 49 | 444 / 1207 ms | 133 ms | 23 ms | 267 ms | 100 ms |
| web（Chrome）、毎秒 2 コマ | 19 / 49 | 505 / 1883 ms | 253 ms | 13 ms | 233 ms | |
| web、毎秒 1 コマ | 4 / 49 | 524 / 1653 ms | 264 ms | 13 ms | 233 ms | |

- 物の検出は 1 秒に 1 回と、場面が変わったとき。物の埋め込みは、新しい物と、10 秒以上埋め込んでいない物だけ（1 回 8 個まで）
- 空欄は、取りこぼしのため物の埋め込みをした回がほとんど無く、中央値に意味がないもの
- メモリ: Android 727〜789 MB、iOS 521〜579 MB（RSS）、web は JS のヒープだけで 100〜143 MB（wasm のメモリは含まない）
- Windows の既定のスレッドでは、parity（1 回ずつ順に）の速さ（D-FINE 265 ms、SigLIP2 37 ms）より replay がさらに遅く出ました（528 ms、186 ms）。理由は確かめていません

### entity と出来事

毎秒 2 コマの 1 回の流れで、5 つのプラットフォームとも（取りこぼしたコマがあっても）:

- 場面: s1（会話）→ s2（ドア）→ s3（群衆）→ s4（コップ）→ **s1 に戻る**
- 顔: 会話の 2 人が f1・f2、群衆の写真の人が f3、会話の後半の人は **f1 として戻る**（`appeared`、`returned`、類似度 0.745）
- 物: 65 個（macOS）。群衆の写真が 40 個（人・車・バス・かばん・傘…）、コップの場面の物が入れ替わりながら 24 個
- 出来事: `appeared`（現れた・戻った）、`left`（2 秒見えなかった）、`scene`（場面が変わった・戻った）の 159 件

entity が持つ埋め込みは kiarina と同じ形です（例、ベクトルは略）:

```json
{
 "id": "f1", "kind": "face", "label": "face", "sightings": 13, "embedding_count": 12,
 "embeddings": [{
  "id": "0hncuc5slc00001", "created_at": "2026-10-19T12:00:00.000Z", "kind": "face",
  "space_id": "sface:sha256=0ba9fbfa…7c34e79:size=112:dim=128:norm=l2",
  "vector": [0.1107, 0.162, -0.0186, -0.08, "…"],
  "metadata": {"bbox": [0.2364, 0.2983, 0.3724, 0.5772], "score": 0.9257, "width": 768, "height": 512}
 }]
}
```

- `space_id` は kiarina の provider と同じ書き方（モデルの sha256・入力の大きさ・次元・正規化）。違う空間のベクトルは比べない
- 1 つの entity が持つ埋め込みは、顔 16・物 4・場面 8 まで。今あるものとのコサインが 0.95 未満の新しい見え方だけを足し、最初の 1 つと新しいほうを残す

### しきい値

`tools/similarity_report.py`（`results/similarity-report.txt`）。「track」は、entity が持つ埋め込みのうちいちばん近いものとの類似度です。

| 比べるもの | コサイン |
| --- | --- |
| 顔: 同じ人（1 枚ずつの組） | 0.336〜0.981（中央値 0.706） |
| 顔: 別の人（1 枚ずつの組） | −0.012〜0.212 |
| 顔: 戻ってきた人と、前半の track | 0.701〜0.893 |
| 顔: 別人（静止画と群衆）と、会話の 2 人の track | 0.021〜0.374 |
| 物: 同じラベル・次のコマ・枠が重なる | 0.943〜1.000 |
| 物: 同じラベルのほかの組 | 0.692〜1.000（中央値 0.940） |
| 物: 違うラベル | 0.573〜0.992 |
| 場面: 同じ場面の続くコマ | 0.941〜1.000 |
| 場面: 場面の切れ目 | 0.483〜0.652 |
| 場面: 会話の前半と後半（同じ場所） | 0.962〜0.986 |
| 場面: 違う場所 | 0.462〜0.835 |

決めた値（`SightConfig` の既定）: 顔は見えている track に 0.363（OpenCV の SFace の推奨）、いなくなった track に 0.5。
場面は今の場面から 0.85 未満で変わったとし、前に見た場面へは 0.90 以上で戻ったとする。物はラベルが同じで枠の IoU 0.3 以上なら同じ track、
いなくなった物へは 0.95 以上で「戻った」とする。

## Architecture

```text
packages/image_analysis   解析（アプリに依存しない Dart のパッケージ）
  RgbImage（BGRA のカメラのコマから）、resizeLinear（OpenCV の固定小数点）、alignFace（Umeyama + 双線形）
  YuNet / SFace / DFine / SigLip2（ONNX Runtime。前処理・後処理は kiarina と同じ）
  SightAnalyzer: コマごとに場面（SigLIP2）→ 顔（YuNet → SFace）→ 物（1 秒ごとと場面の変わり目に D-FINE → 切り抜きを SigLIP2）
  SightStore: entity（f・o・s の番号、埋め込み、小さな切り抜き）と出来事。出来事は 1 時間・5000 件、entity は 1 時間見えないか 500 個を超えたら古いものから消える
  Embedding: kiarina-agi-data の Embedding と同じ項目
app/                      確認用のアプリ（parity・replay・replay-fast）
tools/                    Python の基準データ（fixtures/）と YuNet の変換
```

- 推論は flutter_onnxruntime（method channel）なので、メインの isolate から呼びます。web は onnxruntime-web 1.30.0 を `dart:js_interop` で直接呼びます（音声の lab と同じ。ページが CDN から `ort.min.js` を読み、cross-origin isolated で配信して wasm を複数スレッドにする）。前処理（縮小・整列）は Dart のコードで、今は同じ isolate で動かしています
- モデルは元の配布元から sha256 を確かめてダウンロードします（`ModelCatalog`、合計約 175 MB）。YuNet の変換した ONNX はどこにも公開していないので、アプリに同梱しています
- web のモデルは、ページを開くたびに元の配布元から取り直します（ブラウザの HTTP キャッシュ任せ。SFace は media.githubusercontent.com、ほかは Hugging Face で、どちらも CORS を許している）
- iOS は最低を 16.0 に、Android は `INTERNET` の権限を足しています
- Windows のビルドには、日本語の環境で plugin の C++ の警告がエラーになる（C4819）のを避ける `/utf-8` を足しています（`app/windows/CMakeLists.txt`）

### YuNet

kiarina の `face_detection_yunet_2023mar_int8bq.onnx` は、ONNX Runtime では読めません。bias の DequantizeLinear が per-tensor の scale に
`block_size` を持ち、ONNX Runtime がそれを断るためです。また入力が 1x3x640x640 に固定されていて、OpenCV はそれを無視して画像の大きさ（32 の倍数に詰めたもの）で流します。
`tools/convert_yunet.py` は、定数の DequantizeLinear 64 個を `(q - zero_point) * scale` の float32 に置き換え、入力の縦横を可変にします。
後処理（stride 8・16・32 の復号、`sqrt(cls * obj)`、整数の枠での NMS）は OpenCV の FaceDetectorYN と同じに書きました（`tools/ref_yunet.py`、`detectors.dart`）。

### Python との違い（意図したもの）

- 縮小は OpenCV 本来の固定小数点（arm64 の OpenCV の KleidiCV とは ±1 違う）。顔の整列は倍精度の双線形
- 顔の目印は、正規化してから戻さずに、検出したピクセルの値のまま整列に使う（kiarina は正規化した値に幅を掛け直す）
- entity の追跡と保持は kiarina に無い。この lab で足したもの

## Input

labs の共有アセット（`tests/assets/`）の静止画 3 枚と、動画 3 本・静止画 1 枚を 768x512・毎秒 2 コマにつないだ 24.5 秒の流れ。作り方と sha256 は `tools/README.md` と `fixtures/input.json`。
会話の動画（LTX-2 で作ったもの）を前半と後半に分け、間に別の場面を挟んで、同じ人と場所が戻ってくるようにしています。

## How to run

```sh
mise run //:test-assets:download
# Python の基準データと YuNet の変換（済んでいれば不要）: tools/README.md
mise run prepare                                   # fixtures・コマ（PNG）・埋め込み・YuNet をアプリへ
(cd packages/image_analysis && flutter test)       # 前処理が Python と同じバイトか（推論なし）

MODE=parity mise run macos                         # work/report-macos-parity.json
MODE=replay mise run macos                         # 毎秒 2 コマを実時間で
MODE=replay TAG=replay-fps4 EXTRA_DEFINES="--dart-define=FPS=4" mise run macos
MODE=replay-fast TAG=replay-fast-loops10 EXTRA_DEFINES="--dart-define=LOOPS=10" mise run macos
WIN_HOST=<user@windows-pc> MODE=parity mise run windows
WIN_HOST=<user@windows-pc> MODE=replay TAG=replay-ort8 EXTRA_DEFINES="--dart-define=ORT_THREADS=8" mise run windows
MODE=parity mise run android                       # adb でつないだ端末（logcat から numbered parts を集める）
MODE=parity mise run ios                           # devicectl でつないだ端末（レポートをアプリのコンテナから取り出す）
MODE=parity mise run web                           # cross-origin isolated で配信し、ヘッドレスの Chrome で開く
```

`--dart-define` で渡すもの: `AUTO`（`parity`・`replay`・`replay-fast`）、`AUTO_EXIT`、`RUN_ID`（iOS のタスクが前回のレポートと見分けるため）、`FPS`（既定 2）、`LOOPS`（既定 1）、`ORT_THREADS`（既定は ONNX Runtime 任せ）。
レポートはアプリのデータのフォルダの `report-<OS>-<MODE>.json`（web は `window.resultJson`）。どのプラットフォームでも、`SIGHT_LAB_REPORT i/n` の行にも分けて出します（`tools/join_report.py` で 1 つに戻す）。
`tools/web/serve.py` と `tools/web/run_headless.mjs` は音声の lab から写したもの。

## Environment

- Flutter 3.47.2、flutter_onnxruntime 1.9.0（ONNX Runtime 1.28.3）、onnxruntime-web 1.30.0、image 4.12.0
- macOS: Apple M1 Max MacBook Pro 64 GB、macOS 27.0.1（profile ビルド、10 コア）
- Windows: Core i9-12900K・64 GB、Windows 11（build 26220、profile ビルド、論理 24 コア）
- Android: Pixel 6（Android 17、profile ビルド、arm64、ワイヤレスデバッグ）
- iOS: iPad Air 4（iPadOS 27.0.1、profile ビルド）
- web: headless Chrome 155、同じ M1 Max の Mac（release ビルド、cross-origin isolated、wasm 10 スレッド）
- Python の基準: CPython 3.12.10、opencv-python 5.0.0（KleidiCV の HAL つき）、onnxruntime 1.31.0、numpy 2.5.4（`tools/README.md`）

## 確かめていないこと・制約

- **本物のカメラはまだ**（入力は動画から作った流れだけ）。照明・動き・ピントの外れ・逆光、カメラの BGRA から `RgbImage` への変換の速さ
- 顔のしきい値は、会話の 2 人と静止画・群衆の数人だけで決めた（戻ってきた本人 6 件、別人 24 件）。似た人・横顔・眼鏡・マスク・子ども、多人数の評価はしていない
- 物の re-identification は「手がかり」。同じラベルの別の物と区別する評価はしていない。繰り返すと物の entity が増える（上限と時間で消す）
- SigLIP2 の埋め込みは ONNX Runtime の版で 0.98 ほど動く。版を上げたら、保持した埋め込みと新しい埋め込みを比べる前に確かめ直す
- 長時間（1 時間以上）の連続、熱、ほかのアプリとの取り合い。Windows の既定のスレッドで遅くなる理由
- Linux、iOS のシミュレータ、Safari・Firefox・スマートフォンのブラウザ
- Android・iOS の熱（続けて流した。長く回すと遅くなる見込み）、Android の 32 bit 端末
- web のモデルの保存（開き直すたびに約 175 MB を取り直す）、WebGPU での実行
- 前処理を別の isolate へ逃がすこと（今は推論と同じメインの isolate）
- SigLIP2 の文字側のモデル（「〜が写っているか」を言葉で問う）

## Licenses of the models

YuNet（MIT、OpenCV Zoo）、SFace（Apache-2.0、OpenCV Zoo）、D-FINE（Apache-2.0）、SigLIP2（Apache-2.0）。COCO のラベルは D-FINE の `config.json` から。
URL と sha256 は `packages/image_analysis/lib/src/models/catalog.dart` と `fixtures/input.json`。動画の素材は labs の共有アセット（LTX-2 などで作ったもの）。
