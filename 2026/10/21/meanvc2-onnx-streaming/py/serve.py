#!/usr/bin/env python3
"""Serve build/serve (models, fixtures, manifest) to the app and receive its
reports: POST /report/<name> is written to results/device/<name>.json
(and /report/<name>.f32, the converted audio, to build/device/).

Listens on all interfaces (the phones reach it over the VPN or the LAN)."""
import argparse
import functools
import http.server
import json
import re
from pathlib import Path

LAB = Path(__file__).resolve().parents[1]


class Handler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        m = re.fullmatch(r"/report/([A-Za-z0-9_.-]+)", self.path)
        if not m:
            self.send_error(404)
            return
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        name = m.group(1)
        if name.endswith(".f32"):  # converted audio of the on-device parity (not committed)
            out = LAB / "build/device" / name
        else:
            json.loads(body)
            out = LAB / "results/device" / f"{name}.json"
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(body)
        print(f"[report] {out.relative_to(LAB)} {len(body)} bytes", flush=True)
        self.send_response(204)
        self.end_headers()


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8823)
    a = p.parse_args()
    handler = functools.partial(Handler, directory=str(LAB / "build/serve"))
    http.server.ThreadingHTTPServer(("0.0.0.0", a.port), handler).serve_forever()


if __name__ == "__main__":
    main()
