# MLX 移植の parity 検証

PyTorch 実装を MLX へ移植し、参照実装との一致を検証するときの手順と落とし穴。
2026-08-25 の Mage-VL 移植
([検証方針](mage-vl-mlx-port.md))で実際に確認した内容をまとめたもので、
他のモデルで同じ結論になるかは未検証。新しい移植で反証が出た場合はこの文書を更新する。

## 一致検証は float32 で行う

**異なる backend の bfloat16 同士を比較しても、一致は判定できない。**

Mage-VL(vision tower 24 層 + decoder 36 層)で観測した値。実装は同一で、
dtype だけが異なる。

| 比較 | vision tower cosine | greedy 64 token |
|---|---:|---:|
| MLX fp32 vs PyTorch fp32 | 1.00000000 | 3 枚とも完全一致 |
| MLX bf16 vs PyTorch-MPS bf16 | 0.9988〜0.9992 | 7〜61 / 64 |
| PyTorch CPU bf16 vs PyTorch MPS bf16(同一実装) | 0.99953 | 完全一致 |

3 行目が重要で、**公式実装自身を 2 つの device で走らせただけでも
cosine 0.9999 には届かない**。したがって「cosine 0.9999 以上」のような gate を
bfloat16 で評価する設計は、最初から到達不能である。

実務上の指針。

- gate の数値評価と greedy 一致は float32 の fixture に対して行う
- bfloat16 は実行時精度として扱い、実測値(速度、memory、出力例)を記録する対象にする
- bfloat16 の不一致を見つけても、まず float32 で比較し直してから
  実装の誤りを疑う

## 実装の誤りと数値精度を切り分ける

bfloat16 で一致しないとき、原因が実装か丸めかは次の順で切り分ける。

1. **float32 同士で比較する。** 一致すればロジックは正しく、原因は丸めである。
   Mage-VL では fp32 で相対誤差 1.07e-05、cosine 1.00000000 だった
2. **層ごとに誤差を追う。** 特定の層で跳ねるなら実装の誤り、
   全層で単調に累積するなら丸めである。Mage-VL の bf16 は後者だった
   (layer0 で 5.4e-3 → layer23 で 9.8e-2)
3. **単一演算を float32 化して効果を見る。** 解消するなら、その演算の精度が原因。
   Mage-VL では LayerNorm の fp32 化で cosine 0.998796 → 0.999123 と
   わずかに改善しただけで、attention の fp32 化はむしろ悪化した。
   単一演算の問題ではないと判断できる

相対誤差は比較する位置で大きく変わる点に注意する。値のノルムが小さい正規化直後は、
同じ絶対誤差でも相対誤差が大きく出る。層をまたいで比較するときは
絶対誤差と相対誤差の両方を見る。

## fixture に何を含めるか

最低限、次を固定入力ごとに保存する。

- processor の出力すべて(`input_ids`、`pixel_values`、位置情報など)。
  前処理の一致を独立に検証できるようにする
- 中間出力。vision tower のように差し替え単位となる module の出力を
  forward hook で取る
- 最終位置の logits
- greedy の token 列

あわせて、checkpoint の revision、参照実装の commit、入力ファイルの hash、
dtype、device、ライブラリのバージョンを記録する。

生成コストは device と dtype で桁違いになる。M4 Max で 4.7B parameter の
モデルを forward + greedy 64 token した実測。

| device / dtype | 所要 |
|---|---:|
| CPU float32 | 約 35 秒 |
| MPS bfloat16 | 約 6 秒 |
| CPU bfloat16 | 約 245 秒 |
| MPS float32 | 完走しない(後述) |

CPU は float32 の方が bfloat16 より 7 倍速い。CPU の bf16 は emulation のため。

## 重み変換の gate

変換直後に、参照の全 key が移植側の parameter と過不足なく対応することを確認する。
Mage-VL では 696 key で missing / unused / shape 不一致がいずれも 0 だった。
これは安く、実装の取り違えを早期に検出できる。

`nn.Conv2d` の kernel size と stride が等しく、入力が 1 patch 単位で与えられる場合、
その畳み込みは行列積と等価なので、変換時に `Linear` の重みへ畳んでよい。

## 前処理を bit 一致させる

前処理は演算順序まで合わせれば bit 一致する。合わないときは順序を疑う。

- **transformers は rescale 係数を mean / std に畳み込む**。
  `x / 255` してから正規化するのではなく、mean と std を 255 倍して
  0..255 の値をそのまま正規化する。素直な実装では float32 の 1 ULP
  (4.77e-07)ずれる
- resize の実装(PIL / torchvision / OpenCV)と補間方法は参照実装の分岐に合わせる。
  参照が「A が使えれば A、なければ B」という構造の場合、
  自分の環境でどちらが選ばれているかを実行時に確認する
- 位置情報の生成規則は仕様を読むだけでなく実物を出力して確認する。
  Mage-VL では動画の位置情報の時間軸が 0..T-1 ではなく実 frame 番号だった

## macOS 固有の落とし穴

- **PyTorch MPS の bf16 → fp32 キャストがハングする。**
  `copy_cast_kernel_mps` 内の Metal shader dispatch で進捗なく滞留する。
  73 分間 swap もメモリ逼迫もない状態を確認しているため、待たずに CPU へ切り替える。
  長時間終わらないときは `sample <pid>` でスタックを見ると早い
- **CUDA 前提の依存を持つ checkpoint は、import 検査で止まる。**
  transformers の `check_imports` は remote code の top-level import を静的に見るため、
  実行時に使わない module でも install されていないと失敗する。
  実行時に遅延 import される機能なら、空の stub package を venv に置けば通せる。
  ただし **stub を置いた機能は動かない**ので、その機能を検証する段になったら
  別の手段が要る
- **checkpoint の revision を固定する。** 固定しないと remote code の新版が
  実行中に再ダウンロードされ、再現性が失われる
- remote code は宣言された用途以外の依存を持つことがある。Mage-VL は
  静止画経路でも `cv2` を import した

## 記録

観測した事実と解釈を分け、失敗した試行も残す。上に挙げた落とし穴は、
いずれも最初の実行で踏んで原因を追った結果である。追試する人が同じ時間を
使わずに済むよう、失敗とその原因を lab に書く。
