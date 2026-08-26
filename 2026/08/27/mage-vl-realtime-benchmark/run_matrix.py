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


def summarize(report: dict) -> dict:
    runs = report["runs"]
    segment_rows = [segment for run in runs for segment in run["segments"]]
    return {
        "backend": report["backend"],
        "segment_s": report["segment_s"],
        "runs": len(runs),
        "video_duration_s": report["video_duration_s"],
        "model_dtype": report["model_dtype"],
        "gate_dtype": report["gate_dtype"],
        "max_new_tokens": report["max_new_tokens"],
        "median_real_time_factor": median([run["real_time_factor"] for run in runs]),
        "median_tail_response_s": median([run["tail_response_s"] for run in runs]),
        "median_max_backlog_before_s": median([
            run["max_backlog_before_s"] for run in runs
        ]),
        "all_segments_fit_interval": all(
            run["each_segment_fits_interval"] for run in runs
        ),
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
            raw = raw_dir / f"{backend}-{label}s.json"
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
