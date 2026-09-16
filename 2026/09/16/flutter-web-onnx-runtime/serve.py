"""Serve a Flutter web build (build/web by default) on 127.0.0.1.

--isolate adds COOP/COEP headers so the page becomes crossOriginIsolated,
which onnxruntime-web needs for multi-threaded WebAssembly.
"""

import argparse
import functools
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


class Handler(SimpleHTTPRequestHandler):
    isolate = False

    def end_headers(self) -> None:
        self.send_header("Cache-Control", "no-store")
        if self.isolate:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--isolate", action="store_true")
    parser.add_argument("--root", default="build/web", help="build directory relative to this lab")
    args = parser.parse_args()

    Handler.isolate = args.isolate
    root = Path(__file__).resolve().parent / args.root
    handler = functools.partial(Handler, directory=str(root))
    print(f"Serving {args.root} on http://127.0.0.1:{args.port} (isolate={args.isolate})")
    ThreadingHTTPServer(("127.0.0.1", args.port), handler).serve_forever()


if __name__ == "__main__":
    main()
