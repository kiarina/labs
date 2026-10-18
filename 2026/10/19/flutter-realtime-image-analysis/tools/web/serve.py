#!/usr/bin/env python3
"""Static file server for testing the whisper.cpp web backend locally.

    python3 packages/whisper_cpp/web/serve.py --root <dir> [--port 8787] [--coi [--coep credentialless]]

--coi adds the two headers that make a page cross-origin isolated
(`self.crossOriginIsolated === true`), which the multi-threaded build needs:

    Cross-Origin-Opener-Policy: same-origin
    Cross-Origin-Embedder-Policy: require-corp   (or credentialless, which is
                                                  what `flutter run --cross-origin-isolation` sends)

Without --coi the single-threaded build is used. Also serves .wasm with the
right MIME type (needed for streaming compilation) and disables caching so a
rebuilt module is always picked up.
"""
import argparse
import functools
import http.server


class Handler(http.server.SimpleHTTPRequestHandler):
    coi = False
    coep = "require-corp"
    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".wasm": "application/wasm",
        ".js": "text/javascript",
        ".mjs": "text/javascript",
    }

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        if self.coi:
            self.send_header("Cross-Origin-Opener-Policy", "same-origin")
            self.send_header("Cross-Origin-Embedder-Policy", self.coep)
            self.send_header("Cross-Origin-Resource-Policy", "same-origin")
        super().end_headers()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--coi", action="store_true")
    ap.add_argument("--coep", default="require-corp", choices=["require-corp", "credentialless"])
    a = ap.parse_args()
    Handler.coi = a.coi
    Handler.coep = a.coep
    h = functools.partial(Handler, directory=a.root)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", a.port), h)
    print(f"serving {a.root} on http://127.0.0.1:{a.port} coi={a.coi} coep={a.coep if a.coi else '-'}", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
