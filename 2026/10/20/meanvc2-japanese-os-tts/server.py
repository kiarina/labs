"""Local web UI: upload a reference voice, convert macOS `say` voices with MeanVC2."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import tempfile
import threading
import time
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

import numpy as np
import soundfile as sf

from meanvc2_runtime import MODEL_PRESETS, SAMPLE_RATE, MeanVC2

LAB_DIR = Path(__file__).resolve().parent
WEB_DIR = LAB_DIR / "web"
AUDIO_DIR = LAB_DIR / "output/webui"
MAX_UPLOAD_BYTES = 64 * 1024 * 1024
MAX_SECONDS = 60
SAMPLE_ASSET = "tests/assets/mp3/conversation_2speaker_14s_16k.mp3"
# Known utterance boundaries of the shared two-speaker sample.
SAMPLE_SPEAKERS = {
    "speaker1": ("サンプルの話者 1（共有の会話の素材）", [(0.000, 1.851), (4.737, 7.317), (9.677, 11.834)]),
    "speaker2": ("サンプルの話者 2（共有の会話の素材）", [(1.851, 4.737), (7.317, 9.677), (11.834, 14.171)]),
}


def decode_to_16k(data: bytes, suffix: str) -> np.ndarray:
    """Decode any format macOS Core Audio reads (wav, aiff, mp3, m4a, caf, flac)."""
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / f"input{suffix or '.bin'}"
        target = Path(directory) / "output.wav"
        source.write_bytes(data)
        result = subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1", str(source), str(target)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise ValueError(f"この形式は読めませんでした（afconvert: {result.stderr.strip() or result.returncode}）")
        audio, _ = sf.read(target, dtype="float32")
    return audio


def list_voices() -> list[dict]:
    output = subprocess.run(["say", "-v", "?"], capture_output=True, text=True, check=True).stdout
    voices, seen = [], set()
    for line in output.splitlines():
        match = re.match(r"^(.+?)\s+([a-z]{2,3}_[A-Z0-9]+)\s+#", line)
        if not match or match.group(1) in seen:
            continue
        seen.add(match.group(1))
        voices.append({"name": match.group(1), "locale": match.group(2)})
    voices.sort(key=lambda voice: (voice["locale"] != "ja_JP", voice["locale"], voice["name"]))
    return voices


def synthesize(text: str, voice: str, rate: int | None) -> np.ndarray:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "say.wav"
        command = ["say", "-v", voice, "-o", str(path), "--file-format=WAVE", f"--data-format=LEI16@{SAMPLE_RATE}"]
        if rate:
            command += ["-r", str(rate)]
        subprocess.run(command + ["--", text], check=True, capture_output=True)
        audio, _ = sf.read(path, dtype="float32")
    return audio


def save_audio(audio: np.ndarray, stem: str) -> str:
    AUDIO_DIR.mkdir(parents=True, exist_ok=True)
    name = f"{stem}.wav"
    sf.write(AUDIO_DIR / name, np.clip(audio, -1, 1), SAMPLE_RATE, subtype="PCM_16")
    return f"/audio/{name}"


def describe(audio: np.ndarray) -> dict:
    peak = float(np.max(np.abs(audio))) if len(audio) else 0.0
    rms = float(np.sqrt(np.mean(np.square(audio)))) if len(audio) else 0.0
    return {
        "seconds": round(len(audio) / SAMPLE_RATE, 3),
        "peak_dbfs": round(20 * np.log10(max(peak, 1e-9)), 1),
        "rms_dbfs": round(20 * np.log10(max(rms, 1e-9)), 1),
    }


class Engine:
    def __init__(self, threads: int) -> None:
        self.threads = threads
        self.lock = threading.Lock()
        self.vc: MeanVC2 | None = None
        self.clips: dict[str, dict] = {}  # id -> {label, audio, url, embedding}

    def model(self) -> MeanVC2:
        if self.vc is None:
            self.vc = MeanVC2(LAB_DIR, threads=self.threads)
        return self.vc

    def add_clip(self, audio: np.ndarray, label: str, kind: str) -> dict:
        if len(audio) < SAMPLE_RATE // 2:
            raise ValueError("0.5 秒より短い音は使えません")
        if len(audio) > MAX_SECONDS * SAMPLE_RATE:
            raise ValueError(f"{MAX_SECONDS} 秒より長い音は使えません")
        clip_id = f"{kind}-" + hashlib.sha256(audio.tobytes()).hexdigest()[:12]
        if clip_id not in self.clips:
            self.clips[clip_id] = {
                "id": clip_id,
                "label": label,
                "kind": kind,
                "audio": audio,
                "url": save_audio(audio, clip_id),
                "embedding": None,
            }
        return self.public(self.clips[clip_id])

    @staticmethod
    def public(clip: dict) -> dict:
        return {"id": clip["id"], "label": clip["label"], "kind": clip["kind"], "url": clip["url"], **describe(clip["audio"])}

    def add_samples(self, labs_root: Path) -> None:
        path = labs_root / SAMPLE_ASSET
        if not path.exists():
            print(f"[warn] sample asset not found: {path} (run `mise run //:test-assets:download v1 labs v1`)")
            return
        audio = decode_to_16k(path.read_bytes(), ".mp3")
        for label, segments in SAMPLE_SPEAKERS.values():
            pieces = [audio[int(start * SAMPLE_RATE) : int(end * SAMPLE_RATE)] for start, end in segments]
            # Each sample speaker can be the reference, or a human source to compare with TTS.
            for kind in ("reference", "source"):
                self.add_clip(np.concatenate(pieces), label, kind)

    def convert(self, request: dict) -> dict:
        reference = self.clips.get(request.get("reference_id", ""))
        if reference is None or reference["kind"] != "reference":
            raise ValueError("参照の声を選んでください")
        model = request.get("model", "120ms")
        if model not in MODEL_PRESETS:
            raise ValueError(f"model は {', '.join(MODEL_PRESETS)} のどれか")
        steps = int(request.get("steps", 3))
        if not 1 <= steps <= 8:
            raise ValueError("steps は 1〜8")

        timings: dict[str, float] = {}
        if request.get("source_id"):
            source_clip = self.clips.get(request["source_id"])
            if source_clip is None:
                raise ValueError("元の声のファイルが見つかりません")
            source, source_label = source_clip["audio"], source_clip["label"]
        else:
            text = str(request.get("text", "")).strip()
            voice = str(request.get("voice", ""))
            if not text or not voice:
                raise ValueError("文と OS の声を選んでください")
            if len(text) > 400:
                raise ValueError("文は 400 字まで")
            rate = int(request["rate"]) if request.get("rate") else None
            started = time.perf_counter()
            source = synthesize(text, voice, rate)
            timings["tts"] = time.perf_counter() - started
            source_label = voice

        with self.lock:
            vc = self.model()
            if reference["embedding"] is None:
                started = time.perf_counter()
                reference["embedding"] = vc.speaker_embedding(reference["audio"])
                timings["speaker_embedding"] = time.perf_counter() - started
            result = vc.convert(source, reference["embedding"], model, steps)
        timings["content_features"] = result.bn_seconds
        timings["conversion"] = result.vc_seconds

        stem = f"{int(time.time() * 1000)}"
        source_seconds = len(source) / SAMPLE_RATE
        return {
            "source_label": source_label,
            "reference": self.public(reference),
            "model": model,
            "steps": steps,
            "source": {"url": save_audio(source, f"{stem}-source"), **describe(source)},
            "converted": {"url": save_audio(result.audio, f"{stem}-converted-{model}"), **describe(result.audio)},
            "timings": {key: round(value, 3) for key, value in timings.items()},
            "real_time_factor": round((result.bn_seconds + result.vc_seconds) / max(source_seconds, 1e-6), 3),
        }


class Handler(BaseHTTPRequestHandler):
    engine: Engine

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        print(f"[http] {self.command} {self.path} {args[1] if len(args) > 1 else ''}")

    def send_json(self, payload: object, status: HTTPStatus = HTTPStatus.OK) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_file(self, path: Path, content_type: str) -> None:
        if not path.is_file():
            self.send_error(HTTPStatus.NOT_FOUND)
            return
        body = path.read_bytes()
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length", "0"))
        if length > MAX_UPLOAD_BYTES:
            raise ValueError("ファイルが大きすぎます（64 MB まで）")
        return self.rfile.read(length)

    def do_GET(self) -> None:  # noqa: N802
        if self.path in ("/", "/index.html"):
            self.send_file(WEB_DIR / "index.html", "text/html; charset=utf-8")
        elif self.path == "/api/voices":
            self.send_json(list_voices())
        elif self.path == "/api/clips":
            self.send_json([Engine.public(clip) for clip in self.engine.clips.values()])
        elif self.path.startswith("/audio/"):
            name = Path(unquote(self.path[len("/audio/") :])).name
            self.send_file(AUDIO_DIR / name, "audio/wav")
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        try:
            if self.path.startswith("/api/upload"):
                kind = "source" if "kind=source" in self.path else "reference"
                filename = unquote(self.headers.get("X-Filename", "upload"))
                audio = decode_to_16k(self.read_body(), Path(filename).suffix.lower())
                self.send_json(self.engine.add_clip(audio, filename, kind))
            elif self.path == "/api/convert":
                self.send_json(self.engine.convert(json.loads(self.read_body())))
            else:
                self.send_error(HTTPStatus.NOT_FOUND)
        except (ValueError, KeyError, subprocess.CalledProcessError) as error:
            self.send_json({"error": str(error)}, HTTPStatus.BAD_REQUEST)
        except Exception as error:  # surface model errors in the page
            self.send_json({"error": f"{type(error).__name__}: {error}"}, HTTPStatus.INTERNAL_SERVER_ERROR)
            raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8775)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()

    engine = Engine(args.threads)
    engine.add_samples(Path(os.environ.get("LABS_REPO_ROOT", LAB_DIR.parents[3])))
    print("[model] loading MeanVC2 ...")
    engine.model()
    print(f"[model] loaded in {engine.model().load_seconds:.1f}s")

    Handler.engine = engine
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    url = f"http://{args.host}:{args.port}/"
    print(f"[serve] {url}")
    if not args.no_browser:
        webbrowser.open(url)
    server.serve_forever()


if __name__ == "__main__":
    main()
