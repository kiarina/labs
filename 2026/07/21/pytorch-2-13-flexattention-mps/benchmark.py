#!/usr/bin/env python3
"""Measure compiled FlexAttention and SDPA on Apple Silicon MPS."""

from __future__ import annotations

import argparse
import json
import math
import platform
import statistics
import subprocess
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable

import torch
import torch.nn.functional as F
from torch.nn.attention.flex_attention import create_block_mask, flex_attention


BATCH = 1
HEADS = 8
HEAD_DIM = 64
DTYPE = torch.bfloat16
WARMUPS = 3
TRIALS = 10
CASES = (
    ("causal", 8_192, None),
    ("local", 8_192, 64),
    ("local", 8_192, 256),
    ("local", 8_192, 1_024),
    ("local", 8_192, 4_096),
    ("local", 32_768, 256),
)


@dataclass(frozen=True)
class BenchmarkCase:
    pattern: str
    sequence: int
    window: int | None = None


@dataclass
class Timing:
    median_ms: float
    mean_ms: float
    min_ms: float
    max_ms: float
    stdev_ms: float


def token_density(sequence: int, window: int | None) -> float:
    if window is None or window >= sequence:
        return (sequence + 1) / (2 * sequence)
    allowed = window * (window + 1) / 2 + (sequence - window) * window
    return allowed / (sequence * sequence)


def dense_mask(case: BenchmarkCase, device: torch.device) -> torch.Tensor | None:
    if case.pattern == "causal":
        return None
    mask = torch.ones(
        (case.sequence, case.sequence), dtype=torch.bool, device=device
    ).tril()
    return mask.triu(diagonal=-(case.window - 1))


def mask_function(case: BenchmarkCase) -> Callable:
    if case.pattern == "causal":
        def causal(batch, head, query, key):
            return query >= key
        return causal

    window = case.window

    def local(batch, head, query, key):
        return (query >= key) & ((query - key) < window)

    return local


def synchronize() -> None:
    torch.mps.synchronize()


def time_call(function: Callable[[], torch.Tensor]) -> tuple[Timing, torch.Tensor]:
    output = function()
    synchronize()
    for _ in range(WARMUPS - 1):
        output = function()
        synchronize()

    samples = []
    for _ in range(TRIALS):
        synchronize()
        start = time.perf_counter()
        output = function()
        synchronize()
        samples.append((time.perf_counter() - start) * 1_000)
    return Timing(
        median_ms=statistics.median(samples),
        mean_ms=statistics.mean(samples),
        min_ms=min(samples),
        max_ms=max(samples),
        stdev_ms=statistics.stdev(samples),
    ), output


def run_case(case: BenchmarkCase, device: torch.device) -> dict:
    print(
        f"{case.pattern} S={case.sequence}"
        + (f" W={case.window}" if case.window else "")
    )
    torch.manual_seed(20260721 + case.sequence + (case.window or 0))
    query = torch.randn(
        BATCH, HEADS, case.sequence, HEAD_DIM, device=device, dtype=DTYPE
    )
    key = torch.randn_like(query)
    value = torch.randn_like(query)

    block_mask_start = time.perf_counter()
    block_mask = create_block_mask(
        mask_function(case), BATCH, None, case.sequence, case.sequence,
        device=device,
    )
    synchronize()
    block_mask_build_ms = (time.perf_counter() - block_mask_start) * 1_000
    dense_mask_start = time.perf_counter()
    dense = dense_mask(case, device)
    synchronize()
    dense_mask_build_ms = (time.perf_counter() - dense_mask_start) * 1_000

    compiled_flex = torch.compile(flex_attention, dynamic=False)
    compile_start = time.perf_counter()
    flex_output = compiled_flex(query, key, value, block_mask=block_mask)
    synchronize()
    first_call_ms = (time.perf_counter() - compile_start) * 1_000

    def run_flex() -> torch.Tensor:
        return compiled_flex(query, key, value, block_mask=block_mask)

    def run_sdpa() -> torch.Tensor:
        return F.scaled_dot_product_attention(
            query,
            key,
            value,
            attn_mask=dense,
            is_causal=case.pattern == "causal",
        )

    flex_timing, flex_output = time_call(run_flex)
    sdpa_timing, sdpa_output = time_call(run_sdpa)
    difference = (flex_output.float() - sdpa_output.float()).abs()
    max_abs_error = difference.max().item()
    mean_abs_error = difference.mean().item()
    speedup = sdpa_timing.median_ms / flex_timing.median_ms
    print(
        f"  Flex {flex_timing.median_ms:.3f} ms; "
        f"SDPA {sdpa_timing.median_ms:.3f} ms; {speedup:.2f}x; "
        f"max error {max_abs_error:.6f}"
    )

    result = {
        **asdict(case),
        "token_density_percent": token_density(case.sequence, case.window) * 100,
        "block_density_percent": 100 - block_mask.sparsity(),
        "block_mask_build_ms": block_mask_build_ms,
        "dense_mask_build_ms": dense_mask_build_ms,
        "flex_first_call_ms": first_call_ms,
        "flex": asdict(flex_timing),
        "sdpa": asdict(sdpa_timing),
        "sdpa_over_flex": speedup,
        "max_abs_error": max_abs_error,
        "mean_abs_error": mean_abs_error,
    }
    del query, key, value, block_mask, dense, flex_output, sdpa_output, difference
    torch.mps.empty_cache()
    return result


def backward_probe(device: torch.device) -> dict:
    query = torch.randn(
        1, 2, 128, 32, device=device, dtype=DTYPE, requires_grad=True
    )

    def causal(batch, head, query_index, key_index):
        return query_index >= key_index

    block_mask = create_block_mask(causal, 1, None, 128, 128, device=device)
    try:
        torch.compile(flex_attention)(
            query, query, query, block_mask=block_mask
        ).sum().backward()
        synchronize()
        return {"supported": True, "error": None}
    except NotImplementedError as error:
        message = str(error)
        if "does not support backward on MPS" not in message:
            raise
        return {"supported": False, "error": message}
    finally:
        del query, block_mask
        torch.mps.empty_cache()


def reference_probe(device: torch.device) -> dict:
    case = BenchmarkCase("local", sequence=256, window=64)
    torch.manual_seed(20260721)
    query_cpu = torch.randn(BATCH, HEADS, 256, HEAD_DIM, dtype=torch.float32)
    key_cpu = torch.randn_like(query_cpu)
    value_cpu = torch.randn_like(query_cpu)
    mask_cpu = dense_mask(case, torch.device("cpu"))
    reference = F.scaled_dot_product_attention(
        query_cpu, key_cpu, value_cpu, attn_mask=mask_cpu
    )

    query = query_cpu.to(device=device, dtype=DTYPE)
    key = key_cpu.to(device=device, dtype=DTYPE)
    value = value_cpu.to(device=device, dtype=DTYPE)
    mask = mask_cpu.to(device)
    block_mask = create_block_mask(
        mask_function(case), BATCH, None, 256, 256, device=device
    )
    with torch.inference_mode():
        flex_output = torch.compile(flex_attention, dynamic=False)(
            query, key, value, block_mask=block_mask
        )
        sdpa_output = F.scaled_dot_product_attention(
            query, key, value, attn_mask=mask
        )
    synchronize()

    def errors(output: torch.Tensor) -> dict:
        difference = (output.float().cpu() - reference).abs()
        return {
            "max_abs_error": difference.max().item(),
            "mean_abs_error": difference.mean().item(),
        }

    result = {
        "shape": [BATCH, HEADS, 256, HEAD_DIM],
        "pattern": "local",
        "window": 64,
        "reference": "CPU float32 SDPA",
        "flex_mps_bfloat16": errors(flex_output),
        "sdpa_mps_bfloat16": errors(sdpa_output),
    }
    del query, key, value, mask, block_mask, flex_output, sdpa_output
    torch.mps.empty_cache()
    return result


def command_output(command: list[str]) -> str:
    return subprocess.check_output(command, text=True).strip()


def main(arguments: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--quick", action="store_true", help="skip the memory-intensive 32768 case"
    )
    args = parser.parse_args(arguments)
    if torch.__version__ != "2.13.0":
        raise SystemExit(f"Expected PyTorch 2.13.0, got {torch.__version__}")
    if not torch.backends.mps.is_available():
        raise SystemExit("MPS is not available")

    device = torch.device("mps")
    environment = {
        "machine": platform.machine(),
        "processor": command_output(["sysctl", "-n", "machdep.cpu.brand_string"]),
        "memory_gib": int(command_output(["sysctl", "-n", "hw.memsize"])) / 2**30,
        "macos": platform.mac_ver()[0],
        "python": platform.python_version(),
        "pytorch": torch.__version__,
        "mps_device": torch.backends.mps.get_name(),
        "mps_cores": torch.backends.mps.get_core_count(),
        "recommended_max_memory_gib": torch.mps.recommended_max_memory() / 2**30,
    }
    print(json.dumps(environment, ensure_ascii=False))

    with torch.inference_mode():
        results = [
            run_case(BenchmarkCase(pattern, sequence, window), device)
            for pattern, sequence, window in (CASES[:-1] if args.quick else CASES)
        ]
    reference = reference_probe(device)
    report = {
        "environment": environment,
        "conditions": {
            "batch": BATCH,
            "heads": HEADS,
            "head_dim": HEAD_DIM,
            "dtype": str(DTYPE),
            "warmups": WARMUPS,
            "trials": TRIALS,
        },
        "reference_correctness": reference,
        "backward": backward_probe(device),
        "results": results,
    }
    benchmark_errors = [result["max_abs_error"] for result in results]
    if not all(math.isfinite(error) for error in benchmark_errors):
        raise RuntimeError("FlexAttention or SDPA produced a non-finite value")
    if max(benchmark_errors) > 0.02:
        raise RuntimeError("FlexAttention and SDPA differ by more than 0.02")
    reference_errors = [
        implementation["max_abs_error"]
        for implementation in (
            reference["flex_mps_bfloat16"],
            reference["sdpa_mps_bfloat16"],
        )
    ]
    if not all(math.isfinite(error) for error in reference_errors):
        raise RuntimeError("CPU reference comparison produced a non-finite value")
    if reference_errors[0] > 0.03:
        raise RuntimeError("FlexAttention differs from CPU float32 by more than 0.03")

    output = Path("output/report.json")
    output.parent.mkdir(exist_ok=True)
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(f"report: {output}")


if __name__ == "__main__":
    main()
