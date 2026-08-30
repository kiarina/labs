"""Measure mx.clear_cache() after a real high-memory Mage-VL workload."""

from __future__ import annotations

import argparse
import gc
import json
from pathlib import Path
import statistics
import time

import mlx.core as mx

from mage_vl_mlx.realtime import RealtimeSession, video_duration

GIB = 1024**3


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--video", required=True, type=Path)
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--num-frames", type=int, default=64)
    parser.add_argument("--target-fps", type=float, default=4.0)
    parser.add_argument("--max-new-tokens", type=int, default=2)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()

    template = RealtimeSession.from_pretrained(
        args.weights,
        model_dtype=mx.bfloat16,
        gate_dtype=mx.float32,
        video_backend="frames",
        num_frames=args.num_frames,
        target_fps=args.target_fps,
        gate_threshold=0,
        max_new_tokens=args.max_new_tokens,
    )
    duration = video_duration(args.video)
    trials = []
    for repeat in range(1, args.repeats + 1):
        session = RealtimeSession(
            template.model,
            template.gate,
            template.prompt_builder,
            model_dtype=mx.bfloat16,
            gate_dtype=mx.float32,
            video_backend="frames",
            num_frames=args.num_frames,
            target_fps=args.target_fps,
            gate_threshold=0,
            max_new_tokens=args.max_new_tokens,
        )
        result = session.process_segment(
            args.video,
            "Describe what is happening. Focus on changes and motion.",
            start_s=0,
            end_s=duration,
        )
        processing_s = result.metrics.total_s
        del result, session
        gc.collect()
        cache_before = mx.get_cache_memory()
        active_before = mx.get_active_memory()
        started_ns = time.perf_counter_ns()
        mx.clear_cache()
        elapsed_us = (time.perf_counter_ns() - started_ns) / 1_000
        trials.append({
            "repeat": repeat,
            "processing_s": processing_s,
            "active_before_clear_gib": active_before / GIB,
            "cache_before_clear_gib": cache_before / GIB,
            "elapsed_us": elapsed_us,
            "cache_after_clear_gib": mx.get_cache_memory() / GIB,
        })

    report = {
        "video": args.video.name,
        "weights": args.weights.name,
        "video_duration_s": duration,
        "num_frames": args.num_frames,
        "target_fps": args.target_fps,
        "max_new_tokens": args.max_new_tokens,
        "repeats": args.repeats,
        "summary": {
            "cache_before_clear_gib_median": statistics.median(
                trial["cache_before_clear_gib"] for trial in trials
            ),
            "elapsed_ms_median": statistics.median(
                trial["elapsed_us"] for trial in trials
            ) / 1_000,
            "elapsed_ms_min": min(trial["elapsed_us"] for trial in trials) / 1_000,
            "elapsed_ms_max": max(trial["elapsed_us"] for trial in trials) / 1_000,
        },
        "trials": trials,
    }
    rendered = json.dumps(report, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered + "\n")
    print(rendered)


if __name__ == "__main__":
    main()
