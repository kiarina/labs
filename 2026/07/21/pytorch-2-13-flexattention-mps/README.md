# PyTorch 2.13 FlexAttention on MPS

PyTorch 2.13で追加されたApple Silicon向けFlexAttentionを、MPS上でSDPAと比較します。
Apple M1 Maxでは、token密度0.78%のsliding-window attentionがsequence 8,192で2.15倍、
32,768で7.83倍高速になりました。一方、密度が上がると逆転し、causal attentionでは
SDPAの方が約19倍高速でした。

## Purpose

PyTorch 2.13のrelease blogは、MPS版FlexAttentionが疎なpatternでSDPAより最大約12倍高速に
なる一方、dense patternはSDPAが有利と報告しています。次の問いを同じ代表shapeで確認します。

- 公式例の`1×8×8192×64 / window 64`と`1×8×32768×64 / window 256`をM1 Maxで再現できるか
- sequence長を8192に固定したとき、どの程度のsliding windowでSDPAとの優劣が逆転するか
- compiled FlexAttentionとSDPAの出力は一致するか
- 初回compileとBlockMask生成を含めても実用上有利か
- MPS版でbackwardは利用できるか

## Conditions

query、key、valueは独立な乱数です。両実装へ同じtensorを渡し、mask生成とcompileを除いた
forwardだけを測ります。MPSは非同期なので各計測の直前と直後に`torch.mps.synchronize()`を
呼び、3回warmup後の10回のmedianを採用します。

- shape: batch 1、8 heads、head dimension 64
- dtype: bfloat16
- FlexAttention: `torch.compile(flex_attention, dynamic=False)`
- SDPA: `torch.nn.functional.scaled_dot_product_attention`
- BlockMask tile: default 128×128
- CPU fallback: disabled
- random seed: caseごとに固定

sliding windowは現在位置以前の直近W tokenだけを許可します。token densityは実際に許可される
scoreの割合、block densityは128×128 tile単位でFlex kernelが処理する割合です。window 64では
token density 0.78%に対してblock densityが3.10%となり、tile境界のため理想的な疎性より多く
計算します。

## Run

```sh
mise -C 2026/07/21/pytorch-2-13-flexattention-mps run
```

結果はGit管理外の`output/report.json`へ保存します。
default taskは32,768×32,768のdense boolean mask（単体で1 GiB）も作るため、他のGPU workloadを
終了してから実行してください。memoryに余裕がないMacでは、長いcaseを省く次の実行を使えます。

```sh
uv run python benchmark.py --quick
```

## Observed results

`SDPA / Flex`が1より大きければFlexAttentionが高速です。

| Pattern | Sequence | Window | Token / block density | Flex median | SDPA median | SDPA / Flex |
|---|---:|---:|---:|---:|---:|---:|
| causal | 8,192 | — | 50.01% / 50.78% | 231.22 ms | 12.33 ms | 0.05× |
| local | 8,192 | 64 | 0.78% / 3.10% | 11.75 ms | 25.23 ms | **2.15×** |
| local | 8,192 | 256 | 3.08% / 4.61% | 19.14 ms | 25.25 ms | **1.32×** |
| local | 8,192 | 1,024 | 11.72% / 13.18% | 56.24 ms | 25.30 ms | 0.45× |
| local | 8,192 | 4,096 | 37.50% / 38.67% | 169.24 ms | 25.30 ms | 0.15× |
| local | 32,768 | 256 | 0.78% / 1.17% | 75.27 ms | 589.05 ms | **7.83×** |

10 trialのmin–maxは、8192/window 64でFlex 11.59–11.85 ms、SDPA 25.18–25.30 ms、
8192/window 256でFlex 18.92–19.39 ms、SDPA 25.18–25.43 msでした。32,768/window 256は
Flex 74.96–147.89 ms、SDPA 586.08–590.03 msで、Flex側に1回大きな外れ値がありましたが、
主要な優劣はtrial範囲でも重なりませんでした。

sequence 8192ではwindow 256まではFlexAttentionが勝ち、window 1024ではSDPAが2.22倍高速に
逆転しました。この条件でcross-overはtoken density 3.08%から11.72%の間です。causalは
約50%密度なので、専用pathを持つSDPAがFlexAttentionより18.75倍高速でした。

公式値は8192/window 64で4.15倍、32768/window 256で約12.3倍です。本機では方向性と
長いsequenceほど差が広がる傾向は再現しましたが、speedupはそれぞれ2.15倍と7.83倍で、
公式値には届きませんでした。release blogにはその数値を測ったApple Silicon機種が記載されて
いないため、この差の原因をhardware差だけに帰属させることはできません。

### Setup cost

定常latencyとは別に、一度だけ必要なsetupも測りました。
BlockMaskは公開APIの既定どおりeagerに1回生成し、その後のforwardで同じobjectを再利用します。

| Pattern | Sequence / window | BlockMask build | First compiled call |
|---|---:|---:|---:|
| causal | 8,192 / — | 564.54 ms | 546.57 ms |
| local | 8,192 / 64 | 95.90 ms | 94.31 ms |
| local | 8,192 / 256 | 100.54 ms | 102.34 ms |
| local | 8,192 / 1,024 | 95.02 ms | 130.75 ms |
| local | 8,192 / 4,096 | 96.65 ms | 244.62 ms |
| local | 32,768 / 256 | 1,120.85 ms | 162.57 ms |

32,768/window 256では1回あたり約514 ms短縮しますが、BlockMask生成と初回compileに約1.28秒
かかりました。同じmaskを再利用するなら約3 forwardで回収できます。8192/window 64は1回
あたり約13 msの短縮に対してsetupが約190 msなので、初回callが返す1結果を考慮すると約14
forwardで回収できます。SDPA側のdense mask生成はそれぞれ18.43 msと1.70 msで、この概算には
含めていません。
maskを1回しか使わない処理では、定常latencyのspeedupだけで採用を判断できません。
compile cacheは明示的に消去していないため、first-call値はcold compile時間ではなく、このhostの
cache状態を含む参考値です。`torch.compile(create_block_mask)`でmask生成自体をcompileする経路は
測っていないため、ここでの回収回数はこのeager生成条件だけに適用されます。

### Correctness and supported scope

各benchmark caseで同じMPS bfloat16入力を比較した最大絶対誤差は0.0078125〜0.015625、
平均絶対誤差は0.000079〜0.000363でした。さらに小さい`1×8×256×64 / window 64`を
CPU float32 SDPAと比較しました。

| MPS implementation | Max absolute error | Mean absolute error |
|---|---:|---:|
| FlexAttention bfloat16 | 0.012440 | 0.000553 |
| SDPA bfloat16 | 0.012440 | 0.000677 |

両MPS実装の最大誤差は同じで、FlexAttention固有の大きな乖離は観測しませんでした。
`requires_grad=True`のprobeは
`FlexAttention does not support backward on MPS`で明示的に失敗しました。PyTorch 2.13の
MPS実装はforward inference専用です。

## Interpretation

MPS FlexAttentionの価値は「任意maskなら常にSDPAより速い」ことではなく、長いsequenceの
極端に疎なmaskを、全score行列を計算せずMetal kernelへ落とせることです。本機では8192 token
程度ならwindow 256以下、32768 tokenならwindow 256で明確な利点がありました。

反対にcausalや広いwindowではSDPAを使うべきです。特に通常のcausal attentionをFlexAttention
へ置き換えるだけでは大幅に遅くなります。BlockMaskとcompiled graphを複数layerまたは複数回の
推論で再利用できることも、実用上の重要な前提です。

## Failed attempts and reproducibility notes

最初に未compileの`flex_attention`を呼ぶと、full scores matrixをmaterializeするunfused実装を
使うというwarningが出ました。これは2.13のMPS用fused kernelのbenchmarkにならないため、
全計測を`torch.compile(..., dynamic=False)`へ変更しました。

また、gradient付きtensorはforward呼び出しの時点で`NotImplementedError`になりました。
release blogで追加されたdeterministic backwardはCUDA向けであり、MPS backwardを意味しません。

## Verification environment

- machine: MacBook Pro (MacBookPro18,2)
- chip: Apple M1 Max、32 GPU cores
- memory: 64 GB
- recommended MPS working set: 51.84 GiB
- OS: macOS 26.5.2 (25F84), arm64
- Python: 3.13.7
- PyTorch: 2.13.0
- uv: 0.10.8

## Limitations

- 1台のM1 Max、1回のprocess、synthetic random inputだけを測定した
- 10回の短時間計測であり、長期的なthermal throttlingや他processのGPU負荷を制御していない
- 各caseをFlex、SDPAの固定順で測ったため、順序効果を分離していない
- bfloat16、batch 1、8 heads、head dimension 64だけを測定した
- forward prefillだけを対象とし、decode、GQA、captured buffer、score modificationを試していない
- peak memory、energy、kernel単位のMetal profileを測定していない
- BlockMaskはeager生成だけを測り、compiled mask生成とのsetup比較をしていない
- FlexAttention APIとkernel optionsは2.13時点でprototypeであり、互換性保証がない
- official benchmarkと機種、OS、計測processの全条件が同一ではない

## References

- [PyTorch 2.13 release blog](https://pytorch.org/blog/pytorch-2-13-release-blog/)
- [PyTorch 2.13 FlexAttention documentation](https://docs.pytorch.org/docs/2.13/nn.attention.flex_attention.html)
- [MPS FlexAttention implementation PR](https://github.com/pytorch/pytorch/pull/182552)
- [MPS backend documentation](https://docs.pytorch.org/docs/2.13/notes/mps)
