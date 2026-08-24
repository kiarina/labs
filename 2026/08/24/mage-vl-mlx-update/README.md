# Mage-VL と MLX 対応の追跡調査(2026-08-24)

Mage-VL の MLX 対応状況を追跡するシリーズの 3 本目です。
[Mage-VL on MLX and Apple Silicon](../../05/mage-vl-mlx-mac/README.md)(2026-08-05)と
[Mage-VL codec-native 前処理の macOS 移植性調査](../../05/mage-vl-codec-prep-portability/README.md)(2026-08-05)の続編として、
[Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)の前提が
その後変化していないかを 2026-08-24 時点で再確認した机上調査です。
この lab ではコードを実行していません。

## 目的と問い

- 2026-08-05 の調査以降、mlx-vlm 標準実装の Mage-VL 対応
  (特に動画と proactive streaming)は進んだか
- `codec-video-prep` の配布状況(sdist、macOS wheel、license)に変化はあるか
- codec-native 経路や streaming gate を Apple Silicon 上で再現した報告が現れたか
- 検証方針の stage 構成と gate に修正が必要か

## 調査方法

2026-08-24 に次の公開情報を確認しました。

- `Blaizzy/mlx-vlm` の releases(v0.6.8〜v0.6.15)、issue 1766、
  `mlx_vlm/models/mage_vl` の file 構成
- `mlx-community/Mage-VL-8bit` の model card
- PyPI `codec-video-prep` の JSON API(release file 一覧)
- `microsoft/Mage` repository と `microsoft/Mage-VL` model card
- `rsravanreddy/Mage-VL-MLX` の README
- Apple Silicon 上での codec-native / streaming 再現報告の web 検索

## 観測した事実

### mlx-vlm 標準実装

- v0.6.9(2026-08-03)で `mage_vl` の対応と、video_processor を持たない model 向けの
  汎用「frames fallback」(動画を frame 列に分解して画像として処理)が追加された。
  以後 v0.6.15(2026-08-18)まで release が継続している
- `mlx-community/Mage-VL-8bit` の model card は image に加え 16 frame 動画の
  使用例と測定値を掲載している。M5 Max、macOS 27 上で image 85.7 token/s
  (resident 5.0 GB)、video 16f 80.0 token/s(activation 5.8 GB)、
  BF16 比で greedy 48/48 token 一致、logit cosine 0.9982 と報告されている。
  mlx-vlm 0.6.9 以上を推奨し、retired fork には processor fallback bug が
  あると注意している
- upstream の processor に整合した frame sampling・temporal patch・3D RoPE を求める
  issue 1766 は open のままで、PR もコメントも付いていない。起票者は
  「PyTorch-oracle parity harness を保有している」と記載している
- `mlx_vlm/models/mage_vl` の構成は `config.py`、`language.py`、`vision.py`、
  `processing_mage_vl.py` などで、streaming gate、Mamba、codec に関する
  コードは存在しない

### codec-video-prep package

- 最新は v0.2.5(2026-05-28)のまま更新なし。manylinux wheel のみで
  sdist と macOS wheel はなく、`project_urls` と license は未宣言。
  2026-08-05 の[調査](../../05/mage-vl-codec-prep-portability/README.md)から変化がない

### upstream と第三者移植

- `microsoft/Mage` は 2026-07-26 の Mage-VL 公開以降、大きな release がない
- 公式 model card によると、streaming gate は `inference_streaming.py` と
  同梱の gate 重み(`streammind_gate.safetensors`)で起動し、rolling window ごとに
  発話確率 `p_speak` を算出して閾値超過時のみ本体 VLM の生成を起動する。
  入力には codec backend が推奨されている
- `rsravanreddy/Mage-VL-MLX` は commit 5 件のままで、README は
  model forward 全体の数値検証が未了と記載している
- codec-native 経路または streaming gate の参照実装との一致を Apple Silicon 上で
  確認した報告は、今回の検索では見つからなかった

## 解釈と評価

観測事実に対する本 lab の解釈です。

- Stage 0 の結論(`codec-video-prep` の macOS native build は不可、
  ARM64 Linux container 経由が唯一の現実的経路)は維持できる
- 「標準 mlx-vlm は静止画のみ」という 2026-08-05 時点の前提は崩れた。
  ただし現在動くのは汎用 frames fallback であり、公式実装の frame sampler との
  一致は誰も検証していない。Stage 2 の gate(公式実装との一致)は依然として
  未達成の領域であり、検証の価値は変わらない
- streaming gate(Stage 3)と codec-native 経路(Stage 4)は引き続き空白地帯である。
  mlx-vlm には gate のコード自体が存在しない
- issue 1766 の作業が merge されると Stage 2 の新規性は下がる。
  着手時に状態を再確認し、merge 済みならその実装との差分検証に切り替える

## 検証方針への影響

- [検証方針](../../../../docs/mage-vl-mlx-port.md)の stage 構成と gate は
  変更不要と判断する
- Stage 2 着手時には、その時点の mlx-vlm の video fallback 実装と issue 1766 の
  状態を再確認し、公式 frame sampler との差分を lab に記録する

## 未確認事項と制約

- 本調査はコード実行なし。model card の測定値(M5 Max など)は第三者報告であり、
  独立追試ではない
- v0.6.9 の frames fallback が `mage_vl` に対してどのような frame 選択と前処理を
  行うかは、コードを精読していない
- issue 1766 起票者の parity harness の中身は非公開で確認できない
- 一部の情報は要約ツール経由で取得しており、一次ソースの全文精査ではない

## 参照

シリーズの前の研究:

- [Mage-VL on MLX and Apple Silicon](../../05/mage-vl-mlx-mac/README.md)(2026-08-05)
- [Mage-VL codec-native 前処理の macOS 移植性調査](../../05/mage-vl-codec-prep-portability/README.md)(2026-08-05)
- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)

外部:

- [mlx-vlm releases](https://github.com/Blaizzy/mlx-vlm/releases)
- [mlx-vlm frame-sampled video issue](https://github.com/Blaizzy/mlx-vlm/issues/1766)
- [mlx-vlm mage_vl implementation](https://github.com/Blaizzy/mlx-vlm/tree/main/mlx_vlm/models/mage_vl)
- [MLX 8-bit checkpoint](https://huggingface.co/mlx-community/Mage-VL-8bit)
- [codec-video-prep on PyPI](https://pypi.org/project/codec-video-prep/)
- [Microsoft Mage repository](https://github.com/microsoft/Mage)
- [Microsoft Mage-VL model card](https://huggingface.co/microsoft/Mage-VL)
- [Independent MLX port](https://github.com/rsravanreddy/Mage-VL-MLX)
- [Mage-VL paper](https://arxiv.org/abs/2607.24904)
