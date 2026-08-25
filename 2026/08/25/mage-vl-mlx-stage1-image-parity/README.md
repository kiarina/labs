# Mage-VL 独自 MLX 移植 Stage 1: 静止画 parity

Mage-VL の MLX 移植シリーズの検証です。
[検証方針](../../../../docs/mage-vl-mlx-port.md)の Stage 1(静止画 parity)として、
mlx-vlm に依存しない独自実装を書き、公式 PyTorch 実装との一致を検証しました
(2026-08-25)。前提は
[Mac ベースライン測定](../mage-vl-image-baseline/README.md)と
[fixture の生成 device 比較](../mage-vl-fixture-device/README.md)です。

## 目的と問い

- Mage-ViT、projector、Qwen3 decoder、重みロード、生成ループを MLX で構成し、
  公式実装と一致させられるか
- Stage 1 の gate を満たすか
  - 重み key の missing / unused がともに 0
  - vision tower の相対誤差 `1.0e-4` 以下、cosine 0.9999 以上
  - 参照画像 3 枚以上 × greedy 64 token が fixture と完全一致
- 満たさない場合、原因は実装の誤りか、数値精度か

## 実行方法

移植本体は [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)
commit `313eeea` です。

```sh
git clone https://github.com/kiarina/mage-vl-mlx
cd mage-vl-mlx && git checkout 313eeea
uv sync --group fixtures
.venv/bin/python scripts/install_mamba_stub.py
.venv/bin/python scripts/convert_weights.py

# fixture 生成(float32 は CPU、bfloat16 は MPS)
.venv/bin/python scripts/generate_fixtures.py --image A.jpg --image B.jpg \
  --image C.jpg --devices cpu --dtype float32
.venv/bin/python scripts/generate_fixtures.py --image A.jpg --image B.jpg \
  --image C.jpg --devices mps --dtype bfloat16

.venv/bin/python scripts/check_parity.py --device cpu --dtype float32
.venv/bin/python scripts/check_parity.py --device mps --dtype bfloat16
```

## 検証条件

- 入力: labs 共有アセットの 3 枚
  `objects_1536x1024_358kb.jpg`、`street_scene_1774x887_287kb.jpg`、
  `ocr_1448x1086_242kb.jpg`
- prompt `Describe this image.`、greedy(temperature 0)、64 token
- 参照: `microsoft/Mage-VL` revision `d88b153`、公式 remote code
- 環境: Apple M4 Max、128 GB、macOS 26.5.2、
  torch 2.13.0、transformers 5.15.1、mlx 0.32.1

## 実装の要点

公式 `modeling_mage_vl.py` を読んで次を MLX で再実装しました。

- Mage-ViT 24 層。3D RoPE は head_dim/2 を T:H:W = 4:6:6 に分割し、
  `cat([freqs, freqs])` した角度に **interleaved な rotate_half**
  `(x1,x2,x3,x4) -> (-x2,x1,-x4,x3)` を適用する独特の組み合わせ。
  回転は float32 で計算して元の dtype に戻す
- attention は `cu_seqlens` による block-diagonal。`frame_windows_size=4` で
  t > 4 の sample を分割する。静止画は t=1 なので単一 chunk(全 patch 間 attention)
- MLP の活性は `hidden_act="gelu"`、すなわち tanh 近似ではない厳密な erf GELU
- patch embedding は Conv2d(kernel=stride=patch_size)であり、
  1 patch に対する演算は行列積と等価なため、変換時に Linear へ畳んだ
- merger は LayerNorm → 2x2 patch を 4096 次元に連結 → Linear → GELU → Linear
- decoder は Qwen3 36 層(head_dim 128、q_norm / k_norm、rope_theta 5e6)

## 観測した事実

### 重み key(gate 1)

696 key すべてを写像でき、**missing 0、unused 0、shape 不一致 0**。gate を満たす。

### float32 での一致(gate 2, 3)

float32 CPU fixture に対する結果。

| 画像 | vision 相対誤差 | vision cosine | logits 相対誤差 | greedy |
|---|---:|---:|---:|---:|
| objects | 1.561e-05 | 1.000000 | 1.926e-05 | 64/64 一致 |
| ocr | 1.146e-05 | 1.000000 | 2.664e-05 | 64/64 一致 |
| street_scene | 8.926e-06 | 1.000000 | 8.800e-06 | 64/64 一致 |

相対誤差は gate の `1.0e-4` を下回り、cosine は 0.9999 を上回り、
greedy 64 token は 3 枚すべてで完全一致した。

### bfloat16 では一致しない

同じコードを bfloat16 で MPS bfloat16 fixture と比較すると一致しない。

| 画像 | vision 相対誤差 | vision cosine | greedy |
|---|---:|---:|---:|
| objects | 4.909e-02 | 0.998796 | 31/64 |
| ocr | 4.060e-02 | 0.999176 | 7/64 |
| street_scene | 4.186e-02 | 0.999123 | 61/64 |

### 原因の切り分け

vision tower を層ごとに比較したところ、誤差は特定の層で跳ねず、
24 層かけて単調に累積していた(bfloat16、objects)。

| 位置 | 相対誤差 | cosine |
|---|---:|---:|
| patch embedding | 3.894e-05 | 1.000000 |
| layernorm_pre | 2.817e-03 | 0.999996 |
| layer 0 | 5.441e-03 | 0.999985 |
| layer 1 | 8.656e-03 | 0.999963 |
| layer 11 | 6.254e-02 | 0.998045 |
| layer 23 | 9.791e-02 | 0.995216 |
| merger 出力 | 4.909e-02 | 0.998796 |

同じ実装を float32 で公式 float32 と比較すると
相対誤差 1.069e-05、cosine 1.00000000 だったため、実装ロジックは正しいと判断した。

改善を試みた結果も記録する。いずれも解決しなかった。

- LayerNorm の計算のみ float32 化: cosine 0.998796 → 0.999123(わずかに改善)
- attention(q/k/v と softmax)を float32 化: cosine 0.998796 → 0.998586(悪化)

### 性能(参考)

bfloat16、prompt 1561 token、greedy 64 token、3 回測定。

| 実装 | decode | peak memory |
|---|---:|---:|
| 本移植(MLX bf16) | 21.9 token/s | 9.88 GB(MLX allocator) |
| 公式 PyTorch(MPS bf16) | 16.7 token/s | 9.44 GB(RSS) |
| mlx-vlm 0.6.15(8bit) | 91.5 token/s | 6.83 GB(MLX allocator) |

mlx-vlm は 8bit 量子化であり、bfloat16 の本移植とは条件が異なる。

### 失敗した試行

- `--dtype float32 --devices mps` での fixture 生成は、PyTorch の
  bf16 → fp32 キャスト(`copy_cast_kernel_mps` 内の Metal shader dispatch)で
  ハングした。73 分間、進捗なし・swap なしで同一スタックに滞留したため中断した。
  float32 fixture は CPU で生成する(1 枚 34.9 秒。bfloat16 CPU の 245 秒より速い)
- 最初の fixture 生成 script は vision hook の戻り値を tensor と仮定しており、
  `BaseModelOutputWithPooling` で失敗した

## 解釈と評価

- **Stage 1 は float32 で通過**と判断する。3 つの gate をすべて満たした
- bfloat16 で一致しないのは実装の誤りではなく、MLX と PyTorch-MPS で
  bfloat16 の丸めが異なる形に累積するためと解釈する。根拠は
  (1) float32 では cosine 1.00000000 で一致すること、
  (2) 誤差が単一の層でなく全層にわたって累積すること、
  (3) 単一演算の float32 化では解消しないこと
- gate の数値(相対誤差 1e-4、cosine 0.9999)は、異なる backend の bfloat16 同士の
  比較には最初から到達不能だった。
  [device 比較](../mage-vl-fixture-device/README.md)のとおり、公式実装自身の
  CPU / MPS 間ですら cosine は 0.99953 である。
  したがって **数値 gate は float32 で評価する**と検証方針を改める
- greedy 完全一致 gate は、float32 では 3 枚すべてで成立した。一方 bfloat16 では
  画像により 7/64 から 61/64 までばらついた。logits の cosine が 0.998〜0.9997 でも
  argmax が容易に反転することを示しており、生成一致は数値誤差に対して脆い
- 実用上は bfloat16 で動作し、公式 PyTorch MPS より速い。ただし
  「公式と同一の token 列を出す」ことは bfloat16 では保証されない

## 未確認事項と制約

- 検証は静止画 3 枚、単一 prompt、64 token のみ。長い生成、複数画像入力、
  異なる prompt での挙動は未検証
- float32 fixture の参照は CPU であり、MPS float32 との一致は未検証
  (MPS float32 は上記のとおり生成できていない)
- bfloat16 の不一致が「累積丸め」であることは状況証拠による判断であり、
  演算ごとの誤差寄与を定量分解したわけではない
- 量子化(8bit / 4bit)は未実装・未検証
- KV cache は単純な連結実装で、長い文脈での性能・メモリは最適化していない
- 動画、streaming gate、codec 経路は未実装。本 lab の結論は静止画に限る

## 参照

シリーズの前の研究:

- [Mage-VL 静止画推論の Mac ベースライン](../mage-vl-image-baseline/README.md)(2026-08-25)
- [Mage-VL parity fixture の生成 device 比較](../mage-vl-fixture-device/README.md)(2026-08-25)
- [Mage-VL と MLX 対応の追跡調査](../../24/mage-vl-mlx-update/README.md)(2026-08-24)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)

外部:

- [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)(移植リポジトリ)
- [Microsoft Mage-VL model card](https://huggingface.co/microsoft/Mage-VL)
- [MLX-VLM](https://github.com/Blaizzy/mlx-vlm)
