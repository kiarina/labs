# Mage-VL parity fixture の生成 device 比較(CPU vs MPS)

Mage-VL の MLX 移植シリーズの検証です。
[検証方針](../../../../docs/mage-vl-mlx-port.md)の Stage 1 で使う parity fixture を
どの device で生成すべきかを、公式 PyTorch 実装を CPU と MPS の両方で実行して
比較しました(2026-08-25)。
[Mac ベースライン測定](../mage-vl-image-baseline/README.md)(2026-08-25)で
公式実装が MPS で動くことを確認した続きの検証です。

## 目的と問い

- 公式実装の bfloat16 推論は、CPU と MPS で中間出力・logits・greedy 出力が
  どの程度一致するか
- その一致度は、Stage 1 の gate(vision tower の相対誤差 `1.0e-4` 以下、
  cosine 0.9999 以上)と比べてどの位置にあるか
- fixture の生成 device をどちらにすべきか

## 実行方法

検証コードは移植リポジトリ
[kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx) の
`scripts/generate_fixtures.py`(commit `2944eac`)です。

```sh
git clone https://github.com/kiarina/mage-vl-mlx
cd mage-vl-mlx && git checkout 2944eac
uv sync --group fixtures
.venv/bin/python scripts/install_mamba_stub.py
.venv/bin/python scripts/generate_fixtures.py \
  --image path/to/objects_1536x1024_358kb.jpg --devices cpu,mps
```

入力は labs 共有アセット `tests/assets/jpg/objects_1536x1024_358kb.jpg`
(sha256 `aa973bb3…`)、prompt は `Describe this image.`、greedy 64 token。
checkpoint は `microsoft/Mage-VL` revision `d88b153`、bfloat16。
環境は Apple M4 Max、128 GB、macOS 26.5.2、torch 2.13.0、transformers 5.15.1。

## 観測した事実

| 項目 | CPU bf16 | MPS bf16 | 差 |
|---|---:|---:|---|
| 推論 wall time(forward + greedy 64) | 245.6 秒 | 5.8 秒 | 約 42 倍 |
| processor 出力 pixel_values | - | - | max abs 0.0(完全一致) |
| vision tower 出力(1536×2560) | - | - | max abs 1.069、cosine 0.999527 |
| 最終位置 logits | - | - | max abs 1.016、cosine 0.999600 |
| greedy 64 token | - | - | 完全一致(復号文も同一) |

- 前処理は device に依存せず bit 一致する。差はモデル内部の bfloat16 演算で生じる
- 中間 tensor は device 間で有意に異なる一方、greedy の token 選択は
  この入力では全 64 token で一致した

## 解釈と評価

- Stage 1 gate の「vision tower cosine 0.9999 以上」は、公式実装自身の
  CPU / MPS 間ばらつき(0.99953)より厳しい。したがって gate は
  「どの device で生成した fixture に対してか」を定義しないと評価不能
- fixture の生成 device は **MPS bf16 を正**とする。理由は、
  (1) MLX 実装と同じ Apple GPU 上の値であること、
  (2) CPU 生成は 42 倍遅く、複数画像・動画 fixture の生成に実用的でないこと
- greedy 一致 gate(64 token 完全一致)は device 間の数値ばらつきに対して
  頑健であることが確認でき、gate として妥当
- 中間出力の数値 gate は「MPS fixture に対する cosine 0.9999 以上」を目標として
  維持するが、MLX と MPS の kernel 差が CPU / MPS 差と同程度なら達成できない
  可能性がある。Stage 1 で実測し、満たせない場合は観測値を根拠に gate を
  再設定して記録する

## 未確認事項と制約

- 入力 1 画像、1 prompt のみ。greedy 一致が装飾的でない多様な入力でも
  成立するかは Stage 1 本番の fixture(3 画像以上)で確認する
- float32 参照(CPU fp32)との比較は未実施。bf16 の丸めがどちらの device で
  より大きいかは判定していない
- MPS の実行が run 間で決定的か(同一入力での再現性)は未検証
- 長い生成で greedy が device 間で分岐する可能性は排除できない

## 参照

シリーズの前の研究:

- [Mage-VL 静止画推論の Mac ベースライン](../mage-vl-image-baseline/README.md)(2026-08-25)
- [Mage-VL と MLX 対応の追跡調査](../../24/mage-vl-mlx-update/README.md)(2026-08-24)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)

外部:

- [kiarina/mage-vl-mlx](https://github.com/kiarina/mage-vl-mlx)(移植リポジトリ)
- [Microsoft Mage-VL model card](https://huggingface.co/microsoft/Mage-VL)
