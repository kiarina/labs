#!/usr/bin/env python3
"""Can the ONNX pipeline keep up? Same protocol as the earlier playout lab's
`vc/bench.py`: feed 160 ms chunks back to back (no sleeping), record the
processing time of each chunk, the first-output latency (input buffered until
the chunk that produced the first output + its processing time) and the peak
resident memory. `--backend torch` runs the upstream PyTorch path for
comparison on the same machine.
"""
from __future__ import annotations

import argparse
import json
import os
import platform
import sys
import time
from pathlib import Path

import numpy as np

import inputs
from onnx_stream import CHUNK, VARIANTS, OnnxStreamingVC

LAB = Path(__file__).resolve().parents[1]


def rss_mb() -> float | None:
    """Peak resident memory of this process (not available on Windows here)."""
    if sys.platform == "win32":
        return None
    import resource
    peak = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return peak / (1024 * 1024) if sys.platform == "darwin" else peak / 1024


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--backend", choices=["onnx", "torch"], default="onnx")
    p.add_argument("--variant", default="fp32")
    p.add_argument("--threads", type=int, default=1)
    p.add_argument("--steps", type=int, default=3)
    p.add_argument("--case", default="kyoko")
    p.add_argument("--trials", type=int, default=3)
    p.add_argument("--models", type=Path, default=LAB / "build/onnx")
    p.add_argument("--spk", type=Path, default=LAB / "fixtures/target_spk.npy")
    p.add_argument("--output", type=Path)
    a = p.parse_args()
    source, desc = inputs.source(a.case)
    started = time.perf_counter()
    if a.backend == "onnx":
        vc = OnnxStreamingVC(a.models, suffix=VARIANTS[a.variant], threads=a.threads, steps=a.steps)
        vc.set_target(np.load(a.spk))
        process, reset = vc.process, vc.reset
    else:
        import torch
        from stream_vc import StreamingVC
        vc = StreamingVC(threads=a.threads, model="120ms", steps=a.steps)
        vc.set_target(inputs.target_audio())
        process = lambda x: vc.process(x)  # noqa: E731
        reset = vc.reset
        torch.set_grad_enabled(False)
    load = time.perf_counter() - started
    for _ in range(3):  # warm-up, as upstream realtime mode
        process(np.zeros(CHUNK, np.float32))
    times, first, stages = [], [], []
    for _ in range(a.trials):
        reset()
        fed, first_out = 0, None
        for start in range(0, len(source), CHUNK):
            chunk = source[start:start + CHUNK]
            if len(chunk) < CHUNK:
                chunk = np.pad(chunk, (0, CHUNK - len(chunk)))
            t0 = time.perf_counter()
            y = process(chunk)
            dt = (time.perf_counter() - t0) * 1000
            fed += CHUNK
            times.append(dt)
            if len(y) and first_out is None:
                first_out = fed / 16 + dt
        first.append(first_out)
        if a.backend == "onnx":
            stages.append({k: v * 1000 for k, v in vc.timing.items()})
    arr = np.array(times)
    row = {"backend": a.backend, "variant": a.variant if a.backend == "onnx" else "torch-fp32", "threads": a.threads,
           "steps": a.steps, "case": a.case, "sourceSeconds": len(source) / 16000,
           "machine": platform.machine(), "system": platform.system(), "processor": platform.processor(),
           "loadSeconds": round(load, 2), "chunks": int(len(arr)), "p50Ms": float(np.percentile(arr, 50)),
           "p95Ms": float(np.percentile(arr, 95)), "maxMs": float(arr.max()),
           "deadlineMisses": int(np.sum(arr > CHUNK / 16)), "realTimeFactor": float(arr.mean() / (CHUNK / 16)),
           "firstOutputMs": first, "peakRssMb": rss_mb()}
    if stages:
        n = len(source) / CHUNK
        row["stageMsPerChunk"] = {k: round(np.mean([s[k] for s in stages]) / n, 2) for k in stages[0]}
    print(json.dumps(row), flush=True)
    if a.output:
        a.output.parent.mkdir(parents=True, exist_ok=True)
        with a.output.open("a") as f:
            f.write(json.dumps(row) + "\n")


if __name__ == "__main__":
    main()
