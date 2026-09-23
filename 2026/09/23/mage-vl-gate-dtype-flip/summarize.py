"""Summarize gate-dtype.json: how far each dtype pair moves p(speak), and flips."""

import json
import math
import sys
from collections import defaultdict

import numpy as np

REFERENCE = "f32/f32"
OTHERS = ["bf16/bf16", "bf16/f32", "f32/bf16"]
THRESHOLDS = [0.5, 0.3]


def logit(p: float) -> float:
    p = min(max(p, 1e-12), 1 - 1e-12)
    return math.log(p / (1 - p))


def main() -> None:
    data = json.load(open(sys.argv[1]))
    rows = data["rows"]
    print(f"segments={len(rows)}  nondeterministic_streams={data['nondeterministic_streams']}")

    by_protocol = defaultdict(list)
    for row in rows:
        by_protocol[row["protocol"]].append(row)

    print("\n## |Δp| and |Δlogit| against f32/f32\n")
    print("| protocol | pair | n | median |Δp| | max |Δp| | median |Δlogit| | max |Δlogit| |")
    print("|:---|:---|---:|---:|---:|---:|---:|")
    for protocol, group in by_protocol.items():
        for pair in OTHERS:
            dp = np.array([abs(r["p_speak"][pair] - r["p_speak"][REFERENCE]) for r in group])
            dl = np.array([abs(logit(r["p_speak"][pair]) - logit(r["p_speak"][REFERENCE]))
                           for r in group])
            print(f"| {protocol} | {pair} | {len(group)} | {np.median(dp):.4f} | {dp.max():.4f}"
                  f" | {np.median(dl):.3f} | {dl.max():.3f} |")

    print("\n## flips against f32/f32\n")
    print("| protocol | threshold | ref within ±0.05 | " + " | ".join(OTHERS) + " |")
    print("|:---|---:|---:|" + "---:|" * len(OTHERS))
    for protocol, group in by_protocol.items():
        for t in THRESHOLDS:
            near = sum(abs(r["p_speak"][REFERENCE] - t) <= 0.05 for r in group)
            cells = []
            for pair in OTHERS:
                flips = sum((r["p_speak"][REFERENCE] >= t) != (r["p_speak"][pair] >= t)
                            for r in group)
                cells.append(str(flips))
            print(f"| {protocol} | {t} | {near} | " + " | ".join(cells) + " |")

    print("\n## every flip\n")
    for row in rows:
        p = row["p_speak"]
        for t in THRESHOLDS:
            flipped = [pair for pair in OTHERS if (p[REFERENCE] >= t) != (p[pair] >= t)]
            if flipped:
                print(f"- t={t} {row['video']} {row['protocol']} {row['segment_sec']:g}s "
                      f"#{row['index']}: " + ", ".join(f"{k}={v:.4f}" for k, v in p.items()))

    print("\n## ref p distribution (codec protocols)\n")
    ref = np.array([r["p_speak"][REFERENCE] for r in rows if r["protocol"].startswith("codec")])
    for lo, hi in [(0, 0.1), (0.1, 0.25), (0.25, 0.35), (0.35, 0.45), (0.45, 0.55),
                   (0.55, 0.65), (0.65, 0.9), (0.9, 1.01)]:
        print(f"- [{lo}, {hi}): {int(((ref >= lo) & (ref < hi)).sum())}")


if __name__ == "__main__":
    main()
