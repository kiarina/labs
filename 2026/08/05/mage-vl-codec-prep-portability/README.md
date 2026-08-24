# Mage-VL codec-native 前処理の macOS 移植性調査

[Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md) の
Stage 0 として、codec-native sparse video 経路の前処理を macOS で再現できるかを
2026-08-05 時点で机上調査した記録です。この lab ではコードを実行していません。
前提となる調査は [`mage-vl-mlx-mac`](../mage-vl-mlx-mac/README.md) を参照してください。

## 目的と問い

- `codec-video-prep` のソースは公開されているか。macOS で build できるか
- 公式実装の codec 経路はどう構成され、第三者移植はそれをどう扱っているか
- 論文に patch 選択 algorithm が独立再実装可能な粒度で記述されているか
- macOS(または単一の Mac)で codec-native 経路を再現する具体的な経路はあるか

## 調査方法

2026-08-05 に次の公開情報を確認しました。

- `microsoft/Mage` の `mage_vl` directory と `requirements.txt`
- PyPI `codec-video-prep` の project page と JSON API(release file 一覧)
- `rsravanreddy/Mage-VL-MLX` の README
- [Mage-VL paper](https://arxiv.org/abs/2607.24904) の abstract

## 観測した事実

### 公式実装の codec 経路

- `inference_base.py` は `--video-backend frames | codec` と
  `--codec-engine traditional | neural` を持つ
- traditional engine(H.264 / HEVC)は `codec-video-prep` の `cv-preinfer`
  コマンドを使い、`ffmpeg` と `ffprobe` が `PATH` に必要
- neural engine は DCVC-RT で、checkpoint と CUDA を要求する
- `requirements.txt` は `codec-video-prep>=0.2.5` を固定なしで指定している

### codec-video-prep package(v0.2.5)

- 機能: H.264 / HEVC / VP9 の decoder を instrument して per-macroblock / CTU の
  bitcost map を export し、圧縮性で frame を group 化して informative patch を選択し、
  patch canvas と metadata を出力する
- 配布: manylinux wheel のみ。x86-64(manylinux2014)と aarch64(manylinux_2_35)、
  CPython 3.9–3.13。macOS / Windows wheel はない
- sdist(source 配布)はない。`project_urls` は空で source repository が不明。
  license も metadata 上で未宣言
- native C++ extension `cv_reader_fast` と patched FFmpeg shared library を
  wheel に同梱する

### 第三者移植の扱い

`rsravanreddy/Mage-VL-MLX` は codec canvas 生成を「numpy / MLX で再実装できない
別個の component」と位置づけ、外部で事前生成された codec asset directory を
読み込むだけです。README は Apple Silicon の実用経路を frames backend と明記し、
codec backend は asset がある場合に限るとしています。つまり第三者移植も
canvas 生成自体は macOS 上で実行していません。

### 論文の記述

abstract は「motion vector と residual energy を使い、sparse な I / P frame の
entropy-rich な領域を 16×16 patch level で選択的に符号化し、visual token を
75% 以上削減」と述べるにとどまり、threshold、top-k、canvas packing などの
algorithm 詳細は abstract からは得られません。本文と付録の精査は未実施です。

## 解釈と評価

観測事実に対する本 lab の解釈です。

- macOS native での `codec-video-prep` の build は現状不可能と判断します。
  sdist がなく、source repository が不明で、license も未宣言のため、
  binary の改変・移植の可否も判断できません
- 一方、aarch64 manylinux_2_35 wheel が存在するため、Apple Silicon 上の
  ARM64 Linux container(glibc 2.35 以上、たとえば Ubuntu 22.04 以降)で
  `cv-preinfer` を実行できる可能性が高いと考えます。traditional engine に
  CUDA を要求する記載は確認していません
- したがって「container で codec asset と parity fixture を生成し、macOS 側の
  MLX 実装がその asset を消費する」構成なら、単一の Mac 内で codec-native 経路を
  完結できる見込みがあります
- FFmpeg を独自に改造して per-macroblock bitcost を export する native 再実装は
  技術的には考えられますが、algorithm 詳細の精査と、container 実行で得る
  参照出力との一致検証が前提であり、初期計画には含めません

## 結論(Stage 0 gate 判定)

gate「macOS 上での再現経路を具体的に特定できること」は、条件付きで通過とします。

- 特定した経路: ARM64 Linux container 上で `codec-video-prep` を実行して
  codec asset と参照 fixture を生成し、macOS 側の独自 MLX 実装は canvas 消費以降の
  下流を担う
- 純 macOS native の canvas 生成は現時点では不可。Stage 4 の目標を
  「macOS 単体で完結」から「単一の Mac 上で完結(ARM64 Linux container 併用)」へ
  再定義し、検証方針の文書を更新する

## 未確認事項と制約

- aarch64 wheel が Apple Silicon の container で実際に動作するかは未検証。
  これを次の確認事項とし、動作しない場合は Stage 4 を計画から外す
- traditional engine が GPU を要求しないことを明示的には確認できていない
- 論文本文・付録の algorithm 記述の精査は未実施
- codec asset directory の format 仕様は未確認。第三者移植のコードから
  読み取れる可能性がある
- neural engine(DCVC-RT)は CUDA checkpoint 前提のため、本計画の対象外とする
- `codec-video-prep` は license 未宣言のため、成果公開時の利用条件の確認が必要

## 参照

- [Mage-VL 独自 MLX 移植の検証方針](../../../../docs/mage-vl-mlx-port.md)
- [Microsoft Mage repository](https://github.com/microsoft/Mage/tree/main/mage_vl)
- [Mage-VL requirements](https://github.com/microsoft/Mage/blob/main/mage_vl/requirements.txt)
- [codec-video-prep on PyPI](https://pypi.org/project/codec-video-prep/)
- [Independent MLX port](https://github.com/rsravanreddy/Mage-VL-MLX)
- [Mage-VL paper](https://arxiv.org/abs/2607.24904)
