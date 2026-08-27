"""Run the pinned port's benchmark and summarize repeated measurements."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess


def median(values):
    present = [value for value in values if value is not None]
    return None if not present else statistics.median(present)


def spread(values):
    """Min, median and max, so a single fast or slow run cannot hide in a median."""
    present = [value for value in values if value is not None]
    if not present:
        return None
    return {
        "min": min(present),
        "median": statistics.median(present),
        "max": max(present),
    }


def stage_medians(rows: list) -> dict:
    return {
        "prepare_s": median([row["prepare_s"] for row in rows]),
        "preprocess_s": median([
            row["result"]["metrics"]["preprocess_s"] for row in rows
        ]),
        "vision_s": median([row["result"]["metrics"]["vision_s"] for row in rows]),
        "gate_s": median([row["result"]["metrics"]["gate_s"] for row in rows]),
        "generation_s": median([
            row["result"]["metrics"]["generation_s"] for row in rows
        ]),
        "first_text_after_boundary_s": median([
            row["first_text_after_boundary_s"] for row in rows
        ]),
        "full_response_after_boundary_s": median([
            row["full_response_after_boundary_s"] for row in rows
        ]),
    }


def summarize(report: dict) -> dict:
    runs = report["runs"]
    # Run 1 is the first inference after the weights are loaded. It carries lazy
    # kernel compilation and first-touch allocation, so it is reported apart from
    # the warm runs instead of being averaged into them.
    cold, warm = runs[:1], runs[1:]
    segment_rows = [segment for run in runs for segment in run["segments"]]
    cold_rows = [segment for run in cold for segment in run["segments"]]
    warm_rows = [segment for run in warm for segment in run["segments"]]
    return {
        "backend": report["backend"],
        "segment_s": report["segment_s"],
        "runs": len(runs),
        "video_duration_s": report["video_duration_s"],
        "model_dtype": report["model_dtype"],
        "gate_dtype": report["gate_dtype"],
        "max_new_tokens": report["max_new_tokens"],
        "model_load_s": report["model_load_s"],
        "real_time_factor": spread([run["real_time_factor"] for run in runs]),
        "warm_real_time_factor": spread([run["real_time_factor"] for run in warm]),
        "cold_real_time_factor": (
            cold[0]["real_time_factor"] if cold else None
        ),
        "median_tail_response_s": median([run["tail_response_s"] for run in runs]),
        "median_max_backlog_before_s": median([
            run["max_backlog_before_s"] for run in runs
        ]),
        "all_segments_fit_interval": all(
            run["each_segment_fits_interval"] for run in runs
        ),
        "warm_segments_fit_interval": all(
            run["each_segment_fits_interval"] for run in warm
        ) if warm else None,
        "median_first_text_after_boundary_s": median([
            row["first_text_after_boundary_s"] for row in segment_rows
        ]),
        "median_full_response_after_boundary_s": median([
            row["full_response_after_boundary_s"] for row in segment_rows
        ]),
        "median_prepare_s": median([row["prepare_s"] for row in segment_rows]),
        "median_preprocess_s": median([
            row["result"]["metrics"]["preprocess_s"] for row in segment_rows
        ]),
        "median_vision_s": median([
            row["result"]["metrics"]["vision_s"] for row in segment_rows
        ]),
        "median_gate_s": median([
            row["result"]["metrics"]["gate_s"] for row in segment_rows
        ]),
        "median_generation_s": median([
            row["result"]["metrics"]["generation_s"] for row in segment_rows
        ]),
        "cold": stage_medians(cold_rows) if cold_rows else None,
        "warm": stage_medians(warm_rows) if warm_rows else None,
        "peak_memory_gb": report["peak_memory_gb"],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--video", required=True, type=Path)
    parser.add_argument("--backends", nargs="+", default=["frames"])
    parser.add_argument("--segments", nargs="+", type=float, default=[1, 2, 4, 8])
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--max-new-tokens", type=int, default=16)
    parser.add_argument("--model-dtype", choices=("bfloat16", "float32"), default="bfloat16")
    parser.add_argument("--gate-dtype", choices=("bfloat16", "float32"), default="float32")
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    repo = args.repo.resolve()
    weights = args.weights.resolve()
    video = args.video.resolve()
    raw_dir = args.output.resolve().parent / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    rows = []

    for backend in args.backends:
        for segment_s in args.segments:
            label = str(segment_s).replace(".", "p")
            dtypes = f"{args.model_dtype}-gate{args.gate_dtype}"
            raw = raw_dir / f"{backend}-{label}s-{dtypes}.json"
            command = [
                str(repo / ".venv/bin/python"),
                str(repo / "scripts/benchmark_realtime.py"),
                "--video", str(video),
                "--weights", str(weights),
                "--backend", backend,
                "--segment-sec", str(segment_s),
                "--target-fps", "2",
                "--num-frames", "16",
                "--gate-threshold", "0",
                "--max-new-tokens", str(args.max_new_tokens),
                "--model-dtype", args.model_dtype,
                "--gate-dtype", args.gate_dtype,
                "--runs", str(args.runs),
                "--output", str(raw),
            ]
            environment = os.environ.copy()
            subprocess.run(command, cwd=repo, env=environment, check=True)
            rows.append(summarize(json.loads(raw.read_text())))

    report = {
        "port_commit": subprocess.check_output(
            ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
        ).strip(),
        "video": args.video.name,
        "question": "Describe what is happening. Focus on changes and motion.",
        "rows": rows,
    }
    rendered = json.dumps(report, indent=2)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered + "\n")
    print(rendered)


if __name__ == "__main__":
    main()
