# Qwen3.8-Flash-Next REAP-288 vs full 4-bit vs Qwen3.8-27B on a 128 GB M4 Max

Qwen3.8-Flash-Next (125B MoE + 51B n-gram embedding, 6B active) outscores the
dense Qwen3.8-27B on Qwen's published benchmarks, but its 4-bit MLX weights
take 111.5 GB. The expert-pruned
[REAP-288](https://huggingface.co/sh0wie/Qwen3.8-Flash-Next-REAP-288-MLX-4bit)
build (512 → 288 experts per MoE layer, 73.5 GB) fits a 128 GB Mac with room
to spare, but its saliency was calibrated only on agentic-coding traffic and
its model card reports HumanEval alone.

This lab asks what the pruning costs outside that calibration domain before the
model is adopted for local serving.

## Questions

1. **Japanese:** does REAP-288 lose Japanese knowledge, instruction following,
   reading comprehension, or keigo relative to the full 4-bit build and to
   Qwen3.8-27B?
2. **Long context:** does multi-needle retrieval survive at 32K, 128K, and
   240K tokens? REAP removes only MoE experts; attention, the QSA indexer,
   Gated DeltaNet, routers, and embeddings are untouched.
3. **Agentic work:** can each model finish small multi-step repository fixes
   with tools?
4. **Cost:** peak memory, prefill and decode throughput on this machine.

## Method

All three models run through the same pinned upstream mlx-vlm commit, greedy
decoding (`temperature=0`), thinking disabled (`enable_thinking=False`), and a
2,048-token prefill step. Each model is loaded alone in a fresh process.

| Key | Weights | Revision |
|---|---|---|
| `reap288` | `sh0wie/Qwen3.8-Flash-Next-REAP-288-MLX-4bit` | `668f31bc` |
| `full4bit` | `mlx-community/Qwen3.8-Flash-Next-4bit` | `07b5dc6c` |
| `dense27b` | `mlx-community/Qwen3.8-27B-4bit` | `10c35caa` |

- **Japanese (`data/ja.json`, 32 items):** 16 knowledge, 8 instruction
  following, 6 reading comprehension, 2 keigo. Each item has an automatic check
  (substring, regex, JSON equality, length, line format). Checks are strict on
  format by design; raw outputs are kept for review.
- **Needle:** a deterministic synthetic haystack of Japanese warehouse records
  holds three needles (北門 / 中庭 / 南塔 passwords at 10 / 50 / 90 % depth) and
  three decoys (other gates' passwords). The model must return all three as
  JSON. The text is sized with the Qwen3.8-27B tokenizer so every model reads
  identical characters; each model's own prompt token count is recorded.
- **Agent (`data/agent/`, 4 tasks):** the model gets `list_files`,
  `read_file`, `write_file`, and `run_tests` over a temporary copy of a small
  Python repository, up to 24 steps and 4,096 tokens per step. Success means the
  test files are unmodified and both the visible tests and held-out tests in
  `hidden/` pass. `reference/` holds a known-good fix; `test_eval.py` checks
  that each reference passes and each original fails. Turns reuse the prefix
  with mlx-vlm's automatic prefix cache (APC).

## Reproduce

About 185 GB of weights are downloaded into the normal Hugging Face cache.
Nothing else may use the GPU during a run.

```sh
mise -C 2026/09/24/qwen38-flash-next-reap-eval run test
mise -C 2026/09/24/qwen38-flash-next-reap-eval run eval dense27b
mise -C 2026/09/24/qwen38-flash-next-reap-eval run eval reap288
mise -C 2026/09/24/qwen38-flash-next-reap-eval run eval full4bit
```

`qwen4_exp` memory-maps every n-gram embedding shard, so the `eval` task raises
the open-file limit (`ulimit -n 65536`); with the macOS default of 256 the load
fails with `OSError: [Errno 24] Too many open files`.

Raw records go to the Git-ignored `output/`. `uv run python summarize.py`
rescores the Japanese outputs with the current checks, prints the tables below,
and writes path-redacted copies to `results/`.

The full 4-bit build needed smaller settings to run at all (see Results):

```sh
mise -C 2026/09/24/qwen38-flash-next-reap-eval run eval full4bit ja
mise -C 2026/09/24/qwen38-flash-next-reap-eval run eval full4bit agent --apc-gb 1 --prefill-step 256
mise -C 2026/09/24/qwen38-flash-next-reap-eval run eval full4bit needle --prefill-step 256 --needle-targets 32768 --tag 32768
```

## Results

Environment: Mac Studio, Apple M4 Max, 128 GB unified memory, macOS 26.6.2,
MLX 0.32.2, mlx-vlm 0.7.1 (upstream commit `e79b0e04`), transformers 5.16.1.
Run on 2026-09-24. Peaks are MLX allocator peaks in decimal GB.

**Summary:** REAP-288 keeps long-context retrieval and most coding, but its
general knowledge is broken in every language tried, and it drifts into
Chinese. The full 4-bit build is the best model here but does not fit this
machine beyond short prompts. Qwen3.8-27B is weaker than the full Flash-Next
build but has no failure mode like REAP-288's.

### Japanese (32 items)

| Model | Total | Knowledge | Instruction | Reading | Keigo |
|---|---:|---:|---:|---:|---:|
| dense27b | 30/32 | 15/16 | 7/8 | 6/6 | 2/2 |
| full4bit | 32/32 | 16/16 | 8/8 | 6/6 | 2/2 |
| reap288 | 12/32 | 1/16 | 6/8 | 5/6 | 0/2 |

- Qwen3.8-27B missed 面積最小の都道府県 (answered 鳥取県) and the hiragana
  reading of 東京特許許可局 (とうきゅうとっきょきょく).
- REAP-288 got one knowledge item right (平成). Typical answers: 三重県の県庁所在地
  → 「不存在」, 兼六園 → 「日本」, and a claim in Chinese that the poem 春暁 does
  not exist. (Its 予算の先議権 → 「下院」 fails the check, which wants 衆議院, but
  下院 means the same house; counted by meaning, knowledge is 2/16.) The same prompts to the full 4-bit build
  in the same runtime were answered correctly, so this is the pruning, not the
  runtime. Before the suite, English and Chinese spot checks on REAP-288 also
  failed (it called the longest river in Japan the "Jangwan River" and said
  Japan has no capital), while a Python coding prompt was answered normally.
- **REAP-288's automatic score overstates its quality.** Several passes are
  format-only: the three-bullet answer is written in Chinese, 富士山 is
  described as 「世界最長寿のLinuxディストro」, and the である-style item is
  「灰の天空の光の反射のののの」.
- The `g01` (keigo) check originally required 出席 / 参加 / 伺 and rejected
  the full 4-bit build's correct 「欠席させていただく…お送りいただけますでしょうか」.
  After the runs the pattern was widened to accept 欠席 and all three models
  were rescored from their stored outputs (`summarize.py`). This changed only
  full4bit (31 → 32).

### Needle retrieval (3 needles + 3 decoys)

| Model | Target | Prompt tokens | Found (北門/中庭/南塔) | Prefill tok/s | TTFT s | Peak GB |
|---|---:|---:|---|---:|---:|---:|
| dense27b | 32,768 | 32,767 | o/o/o | 217 | 150.9 | 24.5 |
| dense27b | 131,072 | 131,052 | o/o/o | 152 | 863.0 | 42.0 |
| dense27b | 240,000 | 239,979 | o/o/o | 114 | 2,111.7 | 61.7 |
| full4bit | 32,768 | 32,767 | o/o/o | 297 | 112.1 | 113.8 |
| full4bit | 131,072 | — | Metal OOM | — | — | — |
| reap288 | 32,768 | 32,767 | o/o/o | 574 | 57.1 | 46.4 |
| reap288 | 131,072 | 131,052 | o/o/o | 599 | 218.9 | 51.8 |
| reap288 | 240,000 | 239,979 | o/o/o | 564 | 425.7 | 57.9 |

- Every completed run found all three needles and ignored all three decoys.
  Pruning did not hurt retrieval on this test.
- Flash-Next prefill throughput stays flat with length (REAP-288: 564–599
  tok/s), while Qwen3.8-27B slows from 217 to 114 tok/s. At 240K tokens
  REAP-288 answered in 7 minutes; Qwen3.8-27B took 35.
- The full 4-bit build failed at 32K with the default 2,048-token prefill step
  (`kIOGPUCommandBufferCallbackErrorOutOfMemory`). With a 256-token step it
  completed 32K, which is why its throughput is lower, and then failed at 128K
  with the same error. 240K was not attempted.

### Agentic repository fixes (4 tasks)

| Model | Solved | Steps per task | Notes |
|---|---:|---|---|
| dense27b | 4/4 | 5, 5, 5, 5 | |
| full4bit | 4/4 | 5, 5, 6, 5 | 256-token prefill step and 1 GB APC; see below |
| reap288 | 3/4 | 6, 24, 5, 6 | failed `duration` |

- REAP-288 failed `duration` because it wrote the Japanese unit 時間 as the
  simplified Chinese 时间, in the regex **and** in the docstring's examples. It
  then ran tests and rewrote the file for the remaining steps without finding
  the one-character difference, and once called a nonexistent `edit_file`
  tool. The Chinese drift seen in the Japanese suite also reaches code.
- The full 4-bit build ran out of Metal memory on the first agent task with a
  2,048-token prefill step and a 4 GB APC. It finished with a 256-token step
  and a 1 GB APC, but the APC then reused no tokens (every turn prefilled from
  scratch), so its times are not comparable with the other two.
- Qwen3.8-27B and REAP-288 ran with a 2,048-token prefill step and an 8 GB APC,
  and the APC reused earlier turns for both (the upstream APC works for
  `qwen4_exp`).

### Memory and speed

| Model | Load s | Load peak GB | Decode tok/s (Japanese suite median) |
|---|---:|---:|---:|
| dense27b | 3.1 | 16.1 | 34.3 |
| full4bit | 20.8 | 111.5 | 47.1 |
| reap288 | 6.6 | 41.5 | 37.6 |

- REAP-288's load peak (41.5 GB) is well below its 73.5 GB on disk and the
  model card's 68 GB resident figure. `qwen4_exp` in this mlx-vlm memory-maps
  the n-gram embedding table (`QuantizedMMapNGramEmbedding`), so the table
  probably does not count toward the MLX peak. This was not verified further.
- REAP-288 decoded more slowly than the full build despite having fewer
  experts. Streaming n-gram rows from the memory map is a plausible cause but
  was not measured.

## Scope and limitations

- One machine, one run per configuration, greedy decoding. Agent success
  counts are 4 tasks per model; they show failure modes, not rates.
- Thinking was disabled for every model. Results with thinking enabled may
  differ.
- The Japanese checks are automatic and format-sensitive; the stored outputs
  in `results/` should be read alongside the scores. One check was widened
  after the runs (see above).
- The needle test uses synthetic records, three needles, and one haystack per
  length. It does not measure reasoning over long context.
- The full 4-bit build's failures are under macOS's default GPU wired-memory
  limit (`iogpu.wired_limit_mb` = 0). Raising the limit was not tried, so this
  lab does not show whether it can run long contexts on 128 GB at all.
- Vision input was not tested for any model.
- REAP-288 is one pruning (288 experts, one calibration set). Other expert
  counts or calibration data were not tested.
