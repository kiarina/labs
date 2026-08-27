"""Sample MLX allocator state and the macOS memory view of the live Web UI process.

MLX reports what the process asked its own allocator for. macOS `footprint`
additionally counts Metal's reserved and cached device memory, which is why a
run can show ~12 GB of MLX peak next to a much larger phys_footprint. Both
numbers are read at the same instant here so the gap can be attributed rather
than guessed.

The UI must be started from the pinned port checkout and expose
`/api/memory`. Marks written to the marks file are attached to the next sample,
so a session log stays aligned with the numbers without a second clock.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import urllib.request

GB = 1024.0**3
SIZE_UNITS = {"B": 1.0, "KB": 1024.0, "MB": 1024.0**2, "GB": 1024.0**3, "TB": 1024.0**4}
FOOTPRINT_AUX = re.compile(r"^\s*(phys_footprint(?:_peak)?):\s*([\d.]+)\s*(\w+)\s*$")
FOOTPRINT_SIZE = re.compile(r"^([\d.]+)\s*(\w+)$")


def to_gb(value: str, unit: str) -> float:
    return float(value) * SIZE_UNITS.get(unit.upper(), 0.0) / GB


def read_memory_api(url: str) -> dict:
    with urllib.request.urlopen(f"{url}/api/memory", timeout=5) as response:
        return json.load(response)


def reset_peak(url: str) -> None:
    request = urllib.request.Request(f"{url}/api/memory/reset-peak", method="POST")
    with urllib.request.urlopen(request, timeout=5):
        pass


def read_rss_gb(pid: int) -> float | None:
    """Resident set size in GB, or None if the process is gone."""
    result = subprocess.run(
        ["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True
    )
    value = result.stdout.strip()
    return int(value) * 1024 / GB if value else None


def read_footprint(pid: int) -> dict:
    """phys_footprint plus the largest regions, so the Metal share is visible."""
    result = subprocess.run(
        ["footprint", str(pid)], capture_output=True, text=True
    )
    if result.returncode != 0:
        return {}
    out: dict = {"regions_gb": {}}
    for line in result.stdout.splitlines():
        aux = FOOTPRINT_AUX.match(line)
        if aux is not None:
            out[f"{aux.group(1)}_gb"] = to_gb(aux.group(2), aux.group(3))
            continue
        # Columns are separated by runs of spaces: size, size, size, count, label.
        columns = re.split(r"\s{2,}", line.strip())
        if len(columns) < 2:
            continue
        size_match = FOOTPRINT_SIZE.match(columns[0])
        label = columns[-1].strip()
        if size_match is None or label in {"---", "TOTAL"}:
            continue
        size = to_gb(size_match.group(1), size_match.group(2))
        if size >= 0.1:
            out["regions_gb"][label] = round(size, 3)
    return out


def read_swap_mb() -> float | None:
    result = subprocess.run(
        ["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True
    )
    match = re.search(r"used\s*=\s*([\d.]+)([A-Za-z])", result.stdout)
    if match is None:
        return None
    scale = {"K": 1 / 1024, "M": 1.0, "G": 1024.0}.get(match.group(2).upper(), 1.0)
    return float(match.group(1)) * scale


def read_free_percent() -> int | None:
    result = subprocess.run(["memory_pressure", "-Q"], capture_output=True, text=True)
    match = re.search(r"free percentage:\s*(\d+)", result.stdout)
    return int(match.group(1)) if match is not None else None


def drain_marks(handle) -> list[str]:
    return [line.strip() for line in handle.readlines() if line.strip()]


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    parser.add_argument("--interval", type=float, default=5.0)
    parser.add_argument("--duration", type=float, default=0.0, help="0 runs until interrupted")
    parser.add_argument("--marks", type=Path, default=Path("output/marks.txt"))
    parser.add_argument("--output", type=Path, default=Path("output/memory-samples.jsonl"))
    parser.add_argument(
        "--reset-peak",
        action="store_true",
        help="reset the MLX peak counter once before the first sample",
    )
    args = parser.parse_args()

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.marks.touch()
    if args.reset_peak:
        reset_peak(args.url)

    started = time.time()
    with args.marks.open() as marks, args.output.open("a") as sink:
        marks.seek(0, 2)
        while True:
            pending = drain_marks(marks)
            try:
                api = read_memory_api(args.url)
            except Exception as error:  # the UI may be restarted mid-session
                record = {
                    "t": time.time(),
                    "elapsed_s": round(time.time() - started, 3),
                    "marks": pending,
                    "error": f"{type(error).__name__}: {error}",
                }
                sink.write(json.dumps(record) + "\n")
                sink.flush()
                time.sleep(args.interval)
                continue

            pid = int(api["pid"])
            footprint = read_footprint(pid)
            record = {
                "t": time.time(),
                "elapsed_s": round(time.time() - started, 3),
                "marks": pending,
                "model_loaded": api["model_loaded"],
                "mlx_active_gb": round(api["active_gb"], 3),
                "mlx_cache_gb": round(api["cache_gb"], 3),
                "mlx_peak_gb": round(api["peak_gb"], 3),
                "rss_gb": round(read_rss_gb(pid) or 0.0, 3),
                "footprint_gb": round(footprint.get("phys_footprint_gb", 0.0), 3),
                "footprint_peak_gb": round(footprint.get("phys_footprint_peak_gb", 0.0), 3),
                "footprint_regions_gb": footprint.get("regions_gb", {}),
                "swap_used_mb": read_swap_mb(),
                "system_free_percent": read_free_percent(),
            }
            sink.write(json.dumps(record) + "\n")
            sink.flush()
            if pending:
                print(f"[{record['elapsed_s']:8.1f}s] {', '.join(pending)}", flush=True)

            if args.duration and time.time() - started >= args.duration:
                return
            time.sleep(args.interval)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
