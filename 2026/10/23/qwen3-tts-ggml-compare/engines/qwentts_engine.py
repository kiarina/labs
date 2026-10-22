"""qwentts.cpp (ServeurpersoCom, MIT, pinned in README) through its own OpenAI-compatible `tts-server`.

The server is started once with a talker GGUF and the 12 Hz codec GGUF, the reference is registered as a voice with its
transcript (`wav_b64` + `ref_text`, so the server extracts the x-vector and the reference codes: ICL clone mode B), and each
sentence is a `POST /v1/audio/speech` with `response_format: "pcm"` (s16le 24 kHz streamed as frames are decoded).
Sampling is the engine default, which equals the checkpoint's generation_config.json (0.9 / top-k 50 / top-p 1.0 /
repetition penalty 1.05); the seed is fixed per request.
"""

from __future__ import annotations

import base64
import http.client
import json
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

from download import LAB_DIR, qwentts

from .common import REFERENCE_TEXT, SAMPLE_RATE, Synthesis, footprint_gb, reference_wav

PORT = 18080


def server_binary() -> Path:
    build = LAB_DIR / "vendor/qwentts.cpp/build"
    exe = "tts-server.exe" if sys.platform == "win32" else "tts-server"
    return next(p for p in [build / exe, build / "Release" / exe, build / "bin" / exe, build / "bin" / "Release" / exe] if p.exists())


class Engine:
    def __init__(self, talker: str = "1.7b-base-Q8_0", device: str = "", ref_text: bool = True, max_batch: int = 1) -> None:
        self.talker, self.device, self.ref_text, self.max_batch = talker, device, ref_text, max_batch
        self.name = f"qwentts-{talker}" + ("" if ref_text else "-xvector") + (f"-{device}" if device else "")
        self.description = f"qwentts.cpp tts-server, talker {talker}, codec F32, " + (
            "ICL (reference codes + transcript)" if ref_text else "x-vector only"
        ) + (f", device {device}" if device else ", best device")

    def load(self) -> None:
        talker, codec = qwentts(self.talker)
        args = [str(server_binary()), "--model", talker, "--codec", codec, "--port", str(PORT), "--lang", "Japanese"]
        if self.device:
            args += ["--device", self.device]
        if self.max_batch > 1:
            args += ["--max-batch", str(self.max_batch)]
        self.log = open(LAB_DIR / f"output/{self.name}-server.log", "w")
        self.process = subprocess.Popen(args, stdout=self.log, stderr=subprocess.STDOUT)
        for _ in range(600):
            try:
                self._request("GET", "/v1/models")
                break
            except (ConnectionError, OSError):
                if self.process.poll() is not None:
                    raise RuntimeError(f"tts-server exited ({self.process.returncode}); see {self.log.name}")
                time.sleep(0.5)
        body = {"name": "speaker1", "wav_b64": base64.b64encode(reference_wav().read_bytes()).decode()}
        if self.ref_text:
            body["ref_text"] = REFERENCE_TEXT
        started = time.perf_counter()
        status, data = self._request("POST", "/v1/audio/voices", body)
        assert status == 200, data
        self.register_seconds = time.perf_counter() - started

    def _request(self, method, path, body=None):
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=600)
        conn.request(method, path, json.dumps(body) if body is not None else None, {"Content-Type": "application/json"})
        response = conn.getresponse()
        return response.status, response.read()

    def synthesize(self, text: str, seed: int) -> Synthesis:
        body = {"model": "x", "input": text, "voice": "speaker1", "language": "Japanese", "response_format": "pcm", "seed": seed}
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=600)
        started = time.perf_counter()
        conn.request("POST", "/v1/audio/speech", json.dumps(body), {"Content-Type": "application/json"})
        response = conn.getresponse()
        if response.status != 200:
            raise RuntimeError(response.read().decode(errors="replace"))
        chunks, arrivals, pending = [], [], b""
        while True:
            data = response.read1(65536)
            if not data:
                break
            pending += data
            usable = len(pending) - len(pending) % 2
            if usable:
                chunk = np.frombuffer(pending[:usable], "<i2").astype(np.float32) / 32768.0
                pending = pending[usable:]
                chunks.append(chunk)
                arrivals.append((time.perf_counter() - started, len(chunk) / SAMPLE_RATE))
        elapsed = time.perf_counter() - started
        audio = np.concatenate(chunks) if chunks else np.zeros(0, np.float32)
        return Synthesis(audio, elapsed, arrivals, frames=round(len(audio) / 1920))

    def memory(self) -> dict:
        return {"server_footprint_gb": round(footprint_gb(self.process.pid), 2), "register_seconds": round(self.register_seconds, 3)}

    def close(self) -> None:
        self.process.terminate()
        self.process.wait(timeout=30)
        self.log.close()
