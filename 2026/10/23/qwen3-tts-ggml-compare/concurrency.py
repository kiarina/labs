"""Several requests at once to one qwentts.cpp server (`--max-batch N` batches concurrent requests on the GPU).

For N = 1, 2, 4 simultaneous requests (sentences 0..N-1, seed 0), records each request's RTF, first audio and stalls,
and the throughput (seconds of audio produced per second of wall time). Real time for every stream needs each request's
RTF below 1.

Usage: uv run concurrency.py [--talker 1.7b-base-Q8_0] [--counts 1 2 4]
"""

from __future__ import annotations

import argparse
import json
import platform
import threading
import time

from engines.common import LAB_DIR, SAMPLE_RATE, TEXTS, WARMUP_TEXT, playback_stalls
from engines.qwentts_engine import Engine


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--talker", default="1.7b-base-Q8_0")
    parser.add_argument("--counts", type=int, nargs="*", default=[1, 2, 4])
    args = parser.parse_args()
    (LAB_DIR / "output").mkdir(exist_ok=True)
    engine = Engine(args.talker, max_batch=max(args.counts))
    engine.load()
    engine.synthesize(WARMUP_TEXT, 0)
    rows = []
    try:
        for n in args.counts:
            results = [None] * n

            def run(i):
                results[i] = engine.synthesize(TEXTS[i % len(TEXTS)], 0)

            threads = [threading.Thread(target=run, args=(i,)) for i in range(n)]
            started = time.perf_counter()
            for t in threads:
                t.start()
            for t in threads:
                t.join()
            wall = time.perf_counter() - started
            audio = sum(len(r.audio) for r in results) / SAMPLE_RATE
            row = {
                "concurrent": n,
                "wall_seconds": round(wall, 2),
                "audio_seconds": round(audio, 2),
                "throughput": round(audio / wall, 2),
                "rtf": [round(r.seconds / (len(r.audio) / SAMPLE_RATE), 3) for r in results],
                "first_audio_seconds": [round(r.arrivals[0][0], 3) for r in results],
                "stall_seconds": [round(playback_stalls(r.arrivals), 3) for r in results],
            }
            print(json.dumps(row), flush=True)
            rows.append(row)
    finally:
        engine.close()
    out = LAB_DIR / f"output/concurrency-{args.talker}-{platform.system().lower()}.json"
    out.write_text(json.dumps({"talker": args.talker, "machine": platform.platform(), "rows": rows}, indent=2))


if __name__ == "__main__":
    main()
