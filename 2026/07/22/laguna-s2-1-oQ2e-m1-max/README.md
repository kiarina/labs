# Laguna S 2.1 oQ2e on a 64 GB M1 Max

This lab reproduces the performance-only standardized quant profile from
Tanishq Dubey's Laguna S 2.1 harness on an Apple M1 Max with 64 GB unified
memory. It measures a 16K prefill, a fixed 256-token decode from a 1K prompt,
MLX allocator peak memory, model load time, swap/memory pressure, and a cold
versus warm end-to-end time-to-first-token (TTFT) proxy.

No agent task is run, generated code is never executed, and this lab performs
no external write.

## Question and evaluation

The main question is whether `mlx-community/Laguna-S-2.1-oQ2e` fits and runs
the upstream short profile without swapping on a 64 GB M1 Max. The secondary
question is how the first request after model load differs from later requests.

The upstream profile is reproduced with its fixed seed, prompt construction,
default unquantized KV cache, 2,048-token prefill step, 16K retrieval prompt,
and 1K prompt followed by a 256-token forced decode. Both cases are repeated
three times and the median throughput is reported.

TTFT here is a proxy with an explicit boundary: wall time around
`mlx_vlm.generate(max_tokens=1)` for the same 1K decode prompt, beginning just
before the call and ending when it returns one token. The first measurement is
the first inference request after `lazy=False` model load. It is followed by
five warm measurements. Each trial rebuilds KV state and does not reuse a
prompt cache. This includes prompt formatting inside neither boundary nor model
download/load inside it.

## Reproduce

This downloads about 34 GiB into the normal Hugging Face cache. The model,
runtime packages, model revision, and source harness revision are pinned.

```sh
mise -C 2026/07/22/laguna-s2-1-oQ2e-m1-max run
```

The raw machine-readable record is written under `output/` and is ignored by
Git because it includes machine-specific observations. Reviewed, path-redacted
records are committed as `results.json` for the initial run and
`results-clean.json` for the clean-state rerun.

## Results

The model loaded and completed all requested cases in both runs. The initial
run began with 34.35 GB available and zero swap, but swap rose to 6.49 GB after
`lazy=False` load and was still 2.24 GB after the benchmark. After restarting
macOS and quitting Docker, the rerun began with 56.36 GB available, 11.43 GB
used, 95% system-wide memory free, and zero swap. It completed without swap or
reported throttled pages.

| Measurement | Initial run | Clean-state rerun |
|---|---:|---:|
| Baseline memory available immediately before load | 32.27 GB | 56.36 GB |
| Model load | 14.30 s | 6.98 s |
| First-request TTFT proxy, 1,009-token prompt | 31.66 s | 8.98 s |
| Warm TTFT proxy, 5 trials median | 10.46 s | 7.07 s |
| 16,376-token prefill, 3 trials median | 100.23 token/s | 143.15 token/s |
| 1,009-token prompt + fixed 256-token decode, 3 trials median | 20.52 token/s | 24.16 token/s |
| Peak MLX allocator memory | 38.47 GB | 38.47 GB |
| Swap after load / after benchmark | 6.49 / 2.24 GB | 0 / 0 GB |

The clean-state 16K prefill results were 153.39, 143.15, and 124.23 token/s.
The fixed-decode results were 24.16, 25.88, and 22.98 token/s. Compared with
the initial run, clean-state median prefill was 42.8% higher, median decode was
17.8% higher, and warm TTFT was 32.4% lower. Identical output hashes and the
same 38.47 GB peak support that both runs exercised the same pinned workload.

The result supports a qualified conclusion: this 64 GB M1 Max can complete the
short 16K profile without swap when the system starts in a clean state, but the
fit is sensitive to competing memory use. It does not establish that an
ordinary busy desktop will remain swap-free.

The upstream M5 Max result at the pinned harness revision reports 1,613.07
token/s for the 16K prefill, 55.06 token/s for the fixed decode, and 38.46 GB
peak MLX memory. The M1 and M5 numbers are not normalized: chip, OS, and memory
capacity differ. The near-identical allocator peak confirms comparable model
and prompt shapes, while the M1 run's swap and rising trial speeds prevent
attributing the throughput difference to the GPU alone.

In the clean-state rerun, the first-request TTFT proxy was 1.27 times the warm
median. This supports reporting cold and warm interactive latency separately,
but it does not isolate Metal compilation, prefill, or sampling as individual
causes.

See [`results.json`](results.json) for the initial run and
[`results-clean.json`](results-clean.json) for the clean-state rerun. The
unabridged local captures are retained under the Git-ignored `output/`.

## Scope and limitations

- This is one M1 Max machine with one run in each system state, not a chip-wide
  estimate or a stability study.
- M1 Max results are not normalized against the upstream M5 Max; OS and hardware
  differ even though the model, runtime versions, seed, and prompts are pinned.
- MLX peak memory is allocator-reported decimal GB, not process RSS or total
  system memory.
- The TTFT proxy measures a one-token `generate` call. It is useful for the
  first-versus-warm distinction but is not instrumentation of an interactive
  streaming callback.
- Thermal state and other GPU activity are recorded only indirectly; they are
  not controlled in a laboratory environment.
- The clean-state rerun followed a macOS restart and Docker shutdown, but other
  background processes were not exhaustively isolated. The measured 11.43 GB
  used baseline is not necessarily identical to Activity Monitor's Memory Used
  definition or to a reading taken at another moment.
- 64K, 128K, 256K, quality tasks, and agentic tasks are intentionally not run.

## References

- [Tanishq Dubey's Laguna S 2.1 benchmark harness](https://github.com/tanishq-dubey/macos-laguna-s2.1)
- [Laguna S 2.1 oQ2e model](https://huggingface.co/mlx-community/Laguna-S-2.1-oQ2e)
