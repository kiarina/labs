"""Measure the synchronous cost of releasing MLX's buffer cache."""

from __future__ import annotations

import argparse
import gc
import importlib.metadata
import json
import platform
from pathlib import Path
import statistics
import subprocess
import time

import mlx.core as mx

GIB = 1024**3


def command(*args: str) -> str:
    return subprocess.run(args, capture_output=True, check=True, text=True).stdout.strip()


def fill_cache(target_gib: float, chunk_mib: int) -> dict[str, float]:
    remaining = round(target_gib * GIB)
    chunk_bytes = chunk_mib * 1024**2
    arrays = []
    while remaining:
        size = min(remaining, chunk_bytes)
        array = mx.ones((size // 2,), dtype=mx.float16)
        mx.eval(array)
        arrays.append(array)
        remaining -= size

    active_gib = mx.get_active_memory() / GIB
    del arrays
    if target_gib:
        del array
    gc.collect()
    return {
        "active_before_release_gib": active_gib,
        "cache_before_clear_gib": mx.get_cache_memory() / GIB,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--sizes-gib", type=float, nargs="+", default=[0, 1, 4, 16, 34])
    parser.add_argument("--repeats", type=int, default=7)
    parser.add_argument("--chunk-mib", type=int, default=512)
    parser.add_argument("--port-dir", type=Path, default=Path("output/mage-vl-mlx"))
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    mx.clear_cache()
    trials = []
    for repeat in range(1, args.repeats + 1):
        for target_gib in args.sizes_gib:
            before = fill_cache(target_gib, args.chunk_mib)
            started_ns = time.perf_counter_ns()
            mx.clear_cache()
            elapsed_ns = time.perf_counter_ns() - started_ns
            trials.append({
                "repeat": repeat,
                "target_gib": target_gib,
                **before,
                "elapsed_us": elapsed_ns / 1_000,
                "cache_after_clear_gib": mx.get_cache_memory() / GIB,
            })

    summaries = []
    for target_gib in args.sizes_gib:
        matching = [trial for trial in trials if trial["target_gib"] == target_gib]
        elapsed = [trial["elapsed_us"] for trial in matching]
        summaries.append({
            "target_gib": target_gib,
            "actual_cache_gib_median": statistics.median(
                trial["cache_before_clear_gib"] for trial in matching
            ),
            "elapsed_us_median": statistics.median(elapsed),
            "elapsed_us_min": min(elapsed),
            "elapsed_us_max": max(elapsed),
        })

    report = {
        "measured_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "machine": command("scutil", "--get", "ComputerName"),
        "platform": platform.platform(),
        "port_commit": command("git", "-C", str(args.port_dir), "rev-parse", "HEAD"),
        "mlx_version": importlib.metadata.version("mlx"),
        "method": {
            "dtype": "float16",
            "chunk_mib": args.chunk_mib,
            "repeats": args.repeats,
            "timer": "time.perf_counter_ns around mx.clear_cache only",
        },
        "summaries": summaries,
        "trials": trials,
    }
    rendered = json.dumps(report, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n")
    print(rendered)


if __name__ == "__main__":
    main()
