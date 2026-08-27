"""Calibrate the Web UI's soccer goal preset against a positive and a control clip.

The preset ships with a gate threshold chosen by hand. This runs the same rolling
window the UI runs, with the gate wide open, and records the gate probability and
the generated label for every window. Every threshold can then be evaluated from
one pass instead of re-running the model per threshold.

Ground truth for `soccer_goal` is the shot at t = 6.0-8.0s, recorded in
`2026/08/25/mage-vl-streaming-event-detection`.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
import tempfile
import time

import mlx.core as mx

from mage_vl_mlx.realtime import RealtimeSession, extract_subclip, video_duration

QUESTION = """Classify whether this video window contains the moment a goal is scored in a soccer match.

Answer with exactly one word:
goal — the ball crosses the goal line and a goal is scored
none — anything else, including passing, dribbling, saves and replays

Output only goal or none."""


def windows(duration: float, stride_s: float, window_s: float, min_tail_s: float):
    """Rolling windows ending on each stride boundary, as the UI produces them."""
    end_s = stride_s
    previous_end = 0.0
    while previous_end < duration - 1e-3:
        end = min(duration, end_s)
        if previous_end > 0 and end - previous_end < min_tail_s:
            break
        yield max(0.0, end - window_s), end
        previous_end = end
        end_s += stride_s


def run_clip(session_factory, video: Path, stride_s: float, window_s: float) -> list:
    duration = video_duration(video)
    session = session_factory()
    rows = []
    with tempfile.TemporaryDirectory(dir=video.resolve().parent) as directory:
        for index, (start_s, end_s) in enumerate(
            windows(duration, stride_s, window_s, 0.5), start=1
        ):
            clip = Path(directory) / f"window-{index:04d}.mp4"
            extract_subclip(video, start_s, end_s - start_s, clip)
            # Overlapping windows must not double-count shared frames in the
            # causal gate history, which is what the UI does too.
            session.reset()
            started = time.perf_counter()
            result = session.process_segment(
                clip, QUESTION, start_s=start_s, end_s=end_s
            )
            rows.append({
                "index": index,
                "start_s": start_s,
                "end_s": end_s,
                "probability": result.probability,
                "label": (result.text or "").strip().lower(),
                "work_s": time.perf_counter() - started,
            })
    return rows


def first_label(text: str) -> str:
    import re

    labels = re.findall(r"[\w-]+", text.lower())
    return labels[0] if labels else ""


def evaluate(rows: list, threshold: float, event: tuple | None, cooldown_s: float):
    """Detections surviving the gate, the label and the cooldown, scored against truth."""
    detections = []
    last_at = None
    for row in rows:
        if row["probability"] < threshold:
            continue
        if first_label(row["label"]) != "goal":
            continue
        if last_at is not None and row["end_s"] - last_at < cooldown_s:
            continue
        last_at = row["end_s"]
        detections.append(row["end_s"])
    if event is None:
        # Control clip: every detection is a false positive.
        return {
            "detections": detections,
            "true_positive": 0,
            "false_positive": len(detections),
            "detected_event": None,
        }
    start, end = event
    # A window is a hit when it overlaps the event at all, since the window is
    # what the model actually saw.
    hits = [at for at in detections if at >= start]
    return {
        "detections": detections,
        "true_positive": 1 if hits else 0,
        "false_positive": len(detections) - len(hits),
        "detected_event": min(hits) if hits else None,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--positive", required=True, type=Path)
    parser.add_argument("--control", required=True, type=Path)
    parser.add_argument("--backends", nargs="+", default=["frames", "codec"])
    parser.add_argument("--stride-sec", type=float, default=1.0)
    parser.add_argument("--windows", nargs="+", type=float, default=[4.0])
    parser.add_argument("--cooldown-sec", type=float, default=8.0)
    parser.add_argument("--num-frames", type=int, default=16)
    parser.add_argument("--target-fps", type=float, default=2.0)
    parser.add_argument("--max-new-tokens", type=int, default=2)
    parser.add_argument("--event", nargs=2, type=float, default=[6.0, 8.0])
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    results = []
    for backend in args.backends:
        template = RealtimeSession.from_pretrained(
            args.weights,
            model_dtype=mx.bfloat16,
            gate_dtype=mx.float32,
            video_backend=backend,
        )
        for window_s in args.windows:
            def factory():
                return RealtimeSession(
                    template.model,
                    template.gate,
                    template.prompt_builder,
                    model_dtype=mx.bfloat16,
                    gate_dtype=mx.float32,
                    video_backend=backend,
                    num_frames=args.num_frames,
                    target_fps=args.target_fps,
                    gate_threshold=0.0,
                    max_new_tokens=args.max_new_tokens,
                )

            print(f"running {backend} window={window_s}s", file=sys.stderr, flush=True)
            positive = run_clip(factory, args.positive, args.stride_sec, window_s)
            control = run_clip(factory, args.control, args.stride_sec, window_s)
            results.append({
                "backend": backend,
                "stride_s": args.stride_sec,
                "window_s": window_s,
                "positive_clip": args.positive.name,
                "control_clip": args.control.name,
                "event_s": args.event,
                "positive": positive,
                "control": control,
                "thresholds": {
                    f"{threshold:.2f}": {
                        "positive": evaluate(
                            positive, threshold, tuple(args.event), args.cooldown_sec
                        ),
                        "control": evaluate(
                            control, threshold, None, args.cooldown_sec
                        ),
                    }
                    for threshold in (0.0, 0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 0.8, 0.9)
                },
            })

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"runs": results}, indent=2) + "\n")
    print(json.dumps({"runs": results}, indent=2))


if __name__ == "__main__":
    main()
