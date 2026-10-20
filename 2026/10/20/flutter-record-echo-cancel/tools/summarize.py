#!/usr/bin/env python3
"""Print a Markdown table of results/*.json (or the given files)."""

import json
import sys
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def f(v, fmt="{:.1f}"):
    return "—" if v is None else fmt.format(v)


def main():
    files = [Path(p) for p in sys.argv[1:]] or sorted((LAB / "results").glob("*.json"))
    print("| run | variant | non-zero | silence dBFS | far dBFS / corr | near dBFS / corr | DT far corr | DT near corr |")
    print("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for p in files:
        d = json.loads(p.read_text())
        for r in d.get("results", []):
            v = r["variant"]["name"]
            nz = f"{r.get('nonZeroSamples', 0) / max(1, r.get('samples', 1)):.0%}"
            if (r.get('firstSampleAtMs') or 0) > 1500:
                nz += f" (mic late {r['firstSampleAtMs']} ms)"
            far, near, dt = r.get("far", {}), r.get("near", {}), r.get("doubleTalk", {})
            print(
                f"| {p.stem} | {v} | {nz} | {f(r.get('silenceDbfs'))} "
                f"| {f(far.get('dbfs'))} / {f(far.get('correlation'), '{:.2f}')} "
                f"| {f(near.get('dbfs'))} / {f(near.get('correlation'), '{:.2f}')} "
                f"| {f(dt.get('far', {}).get('correlation'), '{:.2f}')} "
                f"| {f(dt.get('near', {}).get('correlation'), '{:.2f}')} |"
                + (f" error: {r['error']}" if "error" in r else "")
            )


if __name__ == "__main__":
    main()
