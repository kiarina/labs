"""Barge-in: stop a reply mid-sentence and start the next one at once, as the prototype does when the user talks over it.

A long sentence is requested; after `--after` seconds of received audio the client closes the connection (the server stops at
the next frame: `client_gone`), and the next reply is requested immediately. Records how long the server kept generating
after the close (from its `[Pipeline]` log lines), and the next reply's first PCM. Repeated `--repeat` times.

Usage: uv run interrupt.py [--after 1.0] [--repeat 5]
"""

from __future__ import annotations

import argparse
import json
import platform
import re
import time

from engines.common import LAB_DIR, SAMPLE_RATE
from engines.server import Server

LONG = "昔々、ある山のふもとに、小さな村がありました。村の人たちは毎朝、川で水をくみ、畑を耕して、静かに暮らしていました。"
NEXT = "はい、どうしましたか？"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--after", type=float, default=1.0)
    parser.add_argument("--repeat", type=int, default=5)
    args = parser.parse_args()
    server = Server(log_name="server-interrupt")
    rows = []
    try:
        server.stream("こんにちは。", "Japanese", 0, lambda pcm: None)
        for i in range(args.repeat):
            got = {"samples": 0}
            started = time.perf_counter()
            status = server.stream(
                LONG, "Japanese", i, lambda pcm: got.__setitem__("samples", got["samples"] + len(pcm)),
                cancel=lambda: got["samples"] >= args.after * SAMPLE_RATE,
            )
            closed = time.perf_counter()
            first = {}

            def on_pcm(pcm):
                first.setdefault("t", time.perf_counter() - closed)

            server.stream(NEXT, "Japanese", i, on_pcm)
            rows.append({
                "status": status,
                "received_s": round(got["samples"] / SAMPLE_RATE, 3),
                "close_after_request_s": round(closed - started, 3),
                "next_first_pcm_after_close_s": round(first["t"], 3),
            })
            print(json.dumps(rows[-1]), flush=True)
    finally:
        server.close()
    log = (LAB_DIR / "output/server-interrupt.log").read_text(errors="replace")
    stops = re.findall(r"\[Pipeline\][^\n]*(?:cancel|abort|stop|gone)[^\n]*", log, flags=re.I)
    report = {"machine": platform.platform(), "after_s": args.after, "rows": rows, "server_stop_lines": stops[:20]}
    (LAB_DIR / f"output/interrupt-{platform.system().lower()}.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("\n".join(stops[:10]))


if __name__ == "__main__":
    main()
