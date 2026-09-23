# Qwen3.8-Flash-Next full 4-bit with a memory-mapped PLE table on a 128 GB M4 Max

In the [previous lab](../qwen38-flash-next-reap-eval/README.md), the full
4-bit Qwen3.8-Flash-Next (`mlx-community/Qwen3.8-Flash-Next-4bit`, 111.5 GB)
was the best model on every suite but hit Metal out-of-memory errors at 32K
tokens with default settings and at 128K even with a 256-token prefill step.

Qwen3.8-Flash-Next carries a 51B-parameter n-gram embedding table ("PLE") of
which each token reads only a few rows. The `qwen4_exp` implementation in
mlx-vlm can serve that table from a memory map of the safetensors files
(`qwen4_exp/ple_storage.py`) instead of holding it as MLX parameters, but the
`mlx-community` conversion ships without the manifest that enables it.

This lab asks: **does serving the PLE table from a memory map let the full
4-bit build run the same suites with default settings, and what does it cost?**

## Method

`prepare.py` calls mlx-vlm's `prepare_external_ple_model` on the downloaded
checkpoint. It writes `ple-store.json` (byte ranges of the 128 PLE shards
inside the original files), a `config.json` with `text_config.ple_storage`
set, and a filtered weight index, and hard-links the non-PLE weight files.
No weight payload is copied or re-quantized, so the weights are bit-identical; only
where the PLE bytes live at run time changes. The view is written to the
Git-ignored `output/models/`.

The suites, data, checks, runtime pin, and decoding settings are copied
unchanged from the previous lab: 32 Japanese items, multi-needle retrieval at
32K / 128K / 240K tokens with decoys, and 4 agentic repository fixes with tools.
This run uses the **default** settings that failed before: a 2,048-token
prefill step and an 8 GB automatic prefix cache (APC).

## Reproduce

Requires the full 4-bit weights in the Hugging Face cache (about 112 GB) on the
same filesystem as this checkout, for the hard links.

```sh
mise -C 2026/09/24/qwen38-flash-next-ple-mmap run test
mise -C 2026/09/24/qwen38-flash-next-ple-mmap run prepare
mise -C 2026/09/24/qwen38-flash-next-ple-mmap run eval full4bit-plemmap needle,agent,ja
uv run python summarize.py   # rescore, print tables, write results/
```

## Results

Environment: Mac Studio, Apple M4 Max, 128 GB unified memory, macOS 26.6.2,
MLX 0.32.2, mlx-vlm 0.7.1 (upstream `e79b0e04`), run on 2026-09-24. Peaks are
MLX allocator peaks in decimal GB. The comparison rows are from the previous
lab on the same machine and day.

`prepare.py` indexed 320,001,536 PLE rows (width 160, Q4 group 32), 32.0 GB of
PLE bytes, and linked the 17 remaining weight files.

### Memory and speed

| Build | Load peak GB | Decode tok/s (Japanese suite median) |
|---|---:|---:|
| full 4-bit, resident PLE (previous lab) | 111.5 | 47.1 |
| **full 4-bit, memory-mapped PLE** | **79.5** | **40.2** |
| REAP-288 (previous lab, ships a PLE manifest) | 41.5 | 37.6 |
| Qwen3.8-27B (previous lab) | 16.1 | 34.3 |

The load peak fell by 32.0 GB, matching the PLE bytes moved out. Decode was
about 15% slower than with the table resident, still faster than Qwen3.8-27B.

### Needle retrieval

| Build | Target | Prompt tokens | Found | Prefill tok/s | TTFT s | Peak GB |
|---|---:|---:|---|---:|---:|---:|
| full 4-bit, resident PLE | 32,768 | — | Metal OOM at the default prefill step | — | — | — |
| **memory-mapped PLE** | 32,768 | 32,767 | 3/3 | 530 | 63.5 | 83.6 |
| **memory-mapped PLE** | 131,072 | 131,052 | 3/3 | 580 | 226.2 | 89.9 |
| **memory-mapped PLE** | 240,000 | 239,979 | 3/3 | 541 | 443.8 | 96.0 |

All lengths completed with the default settings and found every needle while
ignoring the decoys. The 240K peak (96.0 GB) is the largest observed.

### Agentic repository fixes and Japanese

- Agent: 4/4 solved in 6, 5, 5, 5 steps, with the default prefill step and an
  8 GB APC. The APC reused earlier turns (e.g. 11,694 cached tokens over the
  `csvstats` run); peak 83.1 GB. The previous lab needed a 256-token prefill
  step and a 1 GB APC that reused nothing.
- Japanese: 32/32 (knowledge 16/16, instruction 8/8, reading 6/6, keigo 2/2),
  the same score as the resident build. Checks are identical to the previous
  lab after its `g01` correction.

### Swap

`vm.swapusage` was 3,854.62 MB used before the run (left over from earlier
work) and 3,614.50 MB after. Swap did not grow during the run.

## Conclusion

With the PLE table memory-mapped, the full 4-bit Qwen3.8-Flash-Next runs every
suite on a 128 GB M4 Max with default settings: 240K-token retrieval, agentic
tool use with prefix caching, and unchanged Japanese quality, at about 15% lower
decode speed. It removes the out-of-memory failures that made this build
impractical in the previous lab, without the quality loss of REAP-288.

## Scope and limitations

- One machine, one run, greedy decoding, thinking disabled. Agent success
  counts are 4 tasks.
- The 96 GB peak leaves little room for other models on 128 GB; coexistence
  was not tested.
- The PLE reads come from the page cache or the SSD. This run did not separate
  the two, so a cold cache (for example right after boot) may decode more
  slowly than measured here.
- The decode comparison is one median over 32 short answers per build, run in
  separate processes; the 15% gap is indicative, not a controlled benchmark.
- Vision input was not tested.
- mlx-vlm also offers per-expert SSD offload (`mlx_vlm/moe_offload.py`),
  which could reduce memory further; it was not tried here.
