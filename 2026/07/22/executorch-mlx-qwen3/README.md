# ExecuTorch MLX Delegate with Qwen3 on Apple Silicon

ExecuTorch 1.3.1の実験的なMLX delegateでQwen3-0.6BをBF16とINT4へexportし、
Apple M1 Max上でPyTorch MPS BF16と比較します。固定長生成の中央値では、MLX BF16は
134.8 token/s、MLX INT4は188.9 token/s、PyTorch MPS BF16は41.8 token/sでした。
一方、INT4は3 prompt中2件でBF16と生成tokenが変わり、速度・容量と出力変化のtrade-offも
観測されました。

## Purpose

2026-05-18に公開されたMLX delegateは、PyTorch 2のexport stackからApple Silicon GPU向けの
`.pte`を生成し、Qwen3や2/4/8-bit affine quantizationを扱えるとされています。このlabでは
公式のHugging Face LLM export経路を使い、次を確認します。

- Qwen3-0.6Bの全graphをMLXへdelegateしてPython runtimeで実行できるか
- MLX BF16は同じ重みを使うPyTorch MPS BF16とgreedy生成tokenが一致するか
- INT4でPTE容量、定常decode throughput、process RSSがどう変わるか
- 公開wheelの依存関係だけで再現できるか

成功基準は、BF16とINT4のexport・推論が完走し、MLX BF16が固定promptでPyTorch MPS BF16と
token単位で一致することです。性能値は同一prompt、batch 1、16 token固定生成、各5回のmedianで
比較します。

## Conditions

- model: `Qwen/Qwen3-0.6B`
- model revision: `c1899de289a04d12100db370d81485cdf75e47ca`
- export: ExecuTorch 1.3.1、custom MLX SDPA、custom KV cache、requested max sequence 128
- quantization: BF16、またはlinearとembeddingの4-bit affine（group size 32）
- generation: greedy、batch 1、最大16 token
- performance: 同一の日本語promptを16 tokenで強制継続、warmup後5回のmedian
- output comparison: 3つの固定prompt、EOSで終了、PyTorch MPS BF16をreferenceにtoken列を比較

各backendは独立processで実行します。MLXはtrialごとに`forward` methodをloadしてKV cacheを
初期化し、PyTorchはtrialごとに新しいdynamic cacheを作ります。`load(s)`はMLXではPTE programの
loadだけで、遅延materialization後の全weight展開時間ではありません。RSSはprocess全体のproxyで、
Metal allocatorの使用量と同義ではありません。

## Run

Apple Silicon MacとXcode Command Line Toolsが必要です。初回はPython環境、Hugging Faceの重み、
合計約1.53 GBのPTEを作るため、network・時間・十分な空き容量が必要です。

```sh
mise -C 2026/07/22/executorch-mlx-qwen3 run
```

個別に実行する場合は次のtaskを使います。生成したmodelとreportはGit管理外です。

```sh
mise -C 2026/07/22/executorch-mlx-qwen3 run export
mise -C 2026/07/22/executorch-mlx-qwen3 run benchmark
```

## Observed results

export logではBF16、INT4ともに対象の`call_function` nodeがすべてsupportedとなり、graph全体が
1つのMLX subgraphへpartitionされました。

| PTE | Size | BF16比 | Export time | SHA-256 |
|---|---:|---:|---:|---|
| MLX BF16 | 1,192,264,196 bytes | 100.0% | 41.61 s | `83da47c2…bfb8c0` |
| MLX INT4 | 335,662,976 bytes | 28.2% | 54.55 s | `0e30a054…71267` |

INT4はBF16より856,601,220 bytes、71.8%小さくなりました。

定常性能は「Apple Silicon上のローカル推論について短く説明してください。」を入力し、
warmup後に16 tokenを5回生成したmedianです。prefillは最初の1 tokenまで、decodeは残り15 tokenを
対象にしています。

| Backend | Program/model load | Prefill median | Decode median | Total median | Peak RSS delta |
|---|---:|---:|---:|---:|---:|
| ExecuTorch MLX BF16 | 0.002 s | 0.020 s | 134.8 token/s | 0.131 s | 1.27 GiB |
| ExecuTorch MLX INT4 | 0.003 s | 0.028 s | 188.9 token/s | 0.108 s | 0.47 GiB |
| PyTorch MPS BF16 | 0.726 s | 0.038 s | 41.8 token/s | 0.396 s | 0.14 GiB |

同じ実行条件では、MLX BF16のdecodeはPyTorch MPS BF16の3.22倍、INT4は4.52倍でした。
INT4はMLX BF16より1.40倍高速で、peak RSS deltaは約63%小さくなりました。ただしPyTorch側の
MPS driver allocated memoryは測定終了時1.20 GiBで、表のRSS deltaだけをGPU memory比較として
解釈することはできません。

### Generated tokens

| Prompt | PyTorch MPS BF16 | MLX BF16 | MLX INT4 |
|---|---|---|---|
| 日本の首都 | `日本の首都は、**大阪**です。` | 完全一致 | `日本の首都は、**东京**です。` |
| 1+1 | `1+1=2` | 完全一致 | `1` |
| 文字列の複写 | `MLX` | 完全一致 | 完全一致 |

MLX BF16は3/3件でPyTorch MPS BF16とtoken列が完全一致しました。INT4の完全一致は1/3件です。
首都promptはBF16もINT4も事実として誤ったため、この小規模probeは回答品質の合格を示しません。

最初に公式runnerを単発で起動した際は、BF16のprefillが0.434 s、INT4が1.014 sでした。
warmup後の表より大幅に遅く、Metal setupや初回compileを含むcold latencyを定常値から推定できない
ことも観測しました。

## Interpretation

観測事実として、Qwen3-0.6Bはこの構成で全graphを単一MLX subgraphへlowerでき、MLX BF16は
固定した3 promptでPyTorch MPS BF16と同一tokenを生成しました。少なくともこの範囲では、
delegate境界やcustom KV cacheによる生成差は見つかりませんでした。

性能面ではMLXがMPS eager実行より明確に高速でした。ただし比較対象は同一runtime内のdelegate
差ではなく、ExecuTorch MLX pipelineとTransformers/PyTorch MPS pipelineです。したがって差を
MLX kernelだけに帰属させることはできません。INT4は容量・decode・RSS proxyを改善した一方、
少数promptでも生成を変えました。実用途ではtask固有の品質datasetを加えて採用判断する必要が
あります。

## Failed attempts and reproducibility notes

`executorch==1.3.1`のmetadataは`torch>=2.12.0a0`を許すため、resolverは当初PyTorch 2.13.0を
選びました。しかしprebuilt ExecuTorch extensionのimportが`libc10.dylib`の
`materialize_cow_storage` symbol不足で失敗しました。PyTorchを2.12.1へpinすると同じwheelが
動作しました。失敗を再現する任意taskは次です。このtaskは成功ではなくimport errorを期待します。

```sh
mise -C 2026/07/22/executorch-mlx-qwen3 run probe-torch-2-13
```

またExecuTorch付属のPTE inspectorは、同梱された`flatc`が`--json` optionを認識せず実行できません
でした。delegation範囲はinspectorではなくexport時のpartitioner logで確認しています。

## Verification environment

- machine: MacBook Pro (MacBookPro18,2)
- chip: Apple M1 Max、32 GPU cores
- memory: 64 GB
- OS: macOS 26.5.2 (25F84), arm64
- Xcode: 26.6
- Python: 3.13.7
- ExecuTorch: 1.3.1
- PyTorch: 2.12.1
- Transformers: 4.56.1

## Limitations

- 1台のM1 Max、Qwen3-0.6B、batch 1、短い日本語promptだけを測った
- 5回の短時間計測で、thermal状態、energy、他processのGPU負荷を統制していない
- BF16とINT4だけで、FP16、2/8-bit、XNNPACK、CoreML、AOTI Metalを比較していない
- performance promptを強制的に16 token生成したため、自然なEOSまでのuser-perceived latencyではない
- quality probeは3件だけで、perplexityやtask benchmarkを測っていない
- requested max sequence 128に対しexportされたdynamic constraintの上限は127で、長文を試していない
- RSS samplingは10 ms間隔のprocess proxyで、MLXとMPSのGPU memory accountingを揃えていない
- cold start値は単発観測で、定常benchmarkと同じ反復設計ではない
- MLX delegateはexperimentalであり、APIや対応範囲が変わる可能性がある

## References

- [ExecuTorch MLX delegate announcement (2026-05-18)](https://pytorch.org/blog/running-pytorch-models-on-apple-silicon-gpus-with-the-executorch-mlx-delegate/)
- [ExecuTorch v1.3.1 release notes](https://github.com/pytorch/executorch/releases/tag/v1.3.1)
- [MLX delegate source and examples at v1.3.1](https://github.com/pytorch/executorch/tree/v1.3.1/backends/mlx)
- [Qwen3-0.6B model card](https://huggingface.co/Qwen/Qwen3-0.6B)
