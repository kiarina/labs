"""A qwentts.cpp `tts-server` (pinned in README) with one registered clone voice, and a streaming client for it.

The voice is registered with the reference WAV and its transcript (`wav_b64` + `ref_text`: ICL clone). A synthesis is one
`POST /v1/audio/speech` with `response_format: "pcm"`; s16le 24 kHz arrives frame by frame (1920 samples per frame).
Closing the connection makes the server stop the request at the next frame (`client_gone` in src/tts-server.h).
"""

from __future__ import annotations

import base64
import http.client
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

from download import LAB_DIR, qwentts

from .common import REFERENCE_TEXT, reference_wav

PORT = 18090


def server_binary() -> Path:
    build = LAB_DIR / "vendor/qwentts.cpp/build"
    exe = "tts-server.exe" if sys.platform == "win32" else "tts-server"
    return next(p for p in [build / exe, build / "Release" / exe, build / "bin" / exe] if p.exists())


class Server:
    def __init__(self, max_batch: int = 1, log_name: str = "server") -> None:
        talker, codec = qwentts()
        args = [str(server_binary()), "--model", talker, "--codec", codec, "--port", str(PORT)]
        if max_batch > 1:
            args += ["--max-batch", str(max_batch)]
        (LAB_DIR / "output").mkdir(exist_ok=True)
        self.log = open(LAB_DIR / f"output/{log_name}.log", "w")
        self.process = subprocess.Popen(args, stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(600):
            try:
                self.request("GET", "/v1/models")
                break
            except OSError:
                if self.process.poll() is not None:
                    raise RuntimeError(f"tts-server exited ({self.process.returncode}); see {self.log.name}")
                time.sleep(0.5)
        status, data = self.request(
            "POST", "/v1/audio/voices",
            {"name": "voice", "wav_b64": base64.b64encode(reference_wav().read_bytes()).decode(), "ref_text": REFERENCE_TEXT},
        )
        assert status == 200, data

    def request(self, method, path, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=600)
        conn.request(method, path, json.dumps(body) if body is not None else None, {"Content-Type": "application/json"})
        response = conn.getresponse()
        return response.status, response.read()

    def stream(self, text: str, language: str, seed: int, on_pcm, cancel=lambda: False) -> str:
        """Synthesize `text`, calling on_pcm(float32 array) as PCM arrives. Returns "done" or "canceled"."""
        body = {"model": "x", "input": text, "voice": "voice", "language": language, "response_format": "pcm", "seed": seed}
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=600)
        conn.request("POST", "/v1/audio/speech", json.dumps(body), {"Content-Type": "application/json"})
        response = conn.getresponse()
        if response.status != 200:
            raise RuntimeError(response.read().decode(errors="replace"))
        pending = b""
        while True:
            if cancel():
                conn.sock.shutdown(socket.SHUT_RDWR)
                conn.close()
                return "canceled"
            data = response.read1(65536)
            if not data:
                return "done"
            pending += data
            usable = len(pending) - len(pending) % 2
            if usable:
                on_pcm(np.frombuffer(pending[:usable], "<i2").astype(np.float32) / 32768.0)
                pending = pending[usable:]

    def close(self) -> None:
        self.process.terminate()
        self.process.wait(timeout=30)
        self.log.close()
