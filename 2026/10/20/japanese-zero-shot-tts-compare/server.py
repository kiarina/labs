"""Local web UI: clone a reference voice with CosyVoice 3 and Qwen3-TTS, and listen side by side."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import tempfile
import threading
import time
import webbrowser
from concurrent.futures import ThreadPoolExecutor
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote

import numpy as np
import soundfile as sf

LAB_DIR = Path(__file__).resolve().parent
WEB_DIR = LAB_DIR / "web"
AUDIO_DIR = LAB_DIR / "output/webui"
ENGINES = {
    "qwen3_tts": "Qwen3-TTS",
    "cosyvoice3": "CosyVoice 3",
}
REFERENCE_RATE = 24_000
MAX_UPLOAD_BYTES = 64 * 1024 * 1024
MAX_REFERENCE_SECONDS = 30
WHISPER_REPO = "mlx-community/whisper-large-v3-turbo"
WHISPER_REVISION = "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
SAMPLE_ASSET = "tests/assets/mp3/conversation_2speaker_14s_16k.mp3"
# Known utterance boundaries and transcript of the shared two-speaker sample.
SAMPLE_SPEAKERS = [
    (
        "サンプルの話者 1（共有の会話の素材）",
        [(0.000, 1.851), (4.737, 7.317), (9.677, 11.834)],
        "もしもし、もう駅に着いた？こっちはまだ電車。あと5分くらいかな。助かる。今日は結構寒いね。",
    ),
    ("サンプルの話者 2（共有の会話の素材）", [(1.851, 4.737), (7.317, 9.677), (11.834, 14.171)], None),
]


def decode(data: bytes, suffix: str, rate: int) -> np.ndarray:
    """Decode any format macOS Core Audio reads (wav, aiff, mp3, m4a, caf, flac) to mono."""
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / f"input{suffix or '.bin'}"
        target = Path(directory) / "output.wav"
        source.write_bytes(data)
        result = subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEI16@{rate}", "-c", "1", str(source), str(target)],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            raise ValueError(f"この形式は読めませんでした（afconvert: {result.stderr.strip() or result.returncode}）")
        audio, _ = sf.read(target, dtype="float32")
    return audio


def resample_16k(audio: np.ndarray, rate: int) -> np.ndarray:
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / "in.wav"
        sf.write(path, audio, rate, subtype="PCM_16")
        return decode(path.read_bytes(), ".wav", 16_000)


class Katakana:
    """Pronunciation katakana from UniDic, split by word as in upstream CosyVoice's Japanese example."""

    def __init__(self) -> None:
        import fugashi

        self.tagger = fugashi.Tagger()

    def __call__(self, text: str) -> str:
        words = []
        for word in self.tagger(text):
            pron = getattr(word.feature, "pron", None)
            words.append(pron if pron and pron != "*" else word.surface)
        out = " ".join(words)
        for mark in "、。，．！？!?,.」』）)":
            out = out.replace(f" {mark}", mark)
        for mark in "「『（(":
            out = out.replace(f"{mark} ", mark)
        return out


class Transcriber:
    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.path: str | None = None

    def __call__(self, audio_16k: np.ndarray, language: str) -> str:
        import mlx_whisper
        from huggingface_hub import snapshot_download

        with self.lock:
            if self.path is None:
                self.path = snapshot_download(WHISPER_REPO, revision=WHISPER_REVISION)
                print(f"[whisper] {WHISPER_REPO} at {Path(self.path).name}")
            result = mlx_whisper.transcribe(
                audio_16k.astype(np.float32), path_or_hf_repo=self.path, language=language, temperature=0.0
            )
        return result["text"].strip()


class Worker:
    """A TTS engine in its own Python environment, spoken to with JSON lines."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.lock = threading.Lock()
        self.state = "starting"
        self.error: str | None = None
        self.process: subprocess.Popen | None = None
        self.replies = None
        threading.Thread(target=self._start, daemon=True).start()

    def _start(self) -> None:
        directory = LAB_DIR / "engines" / self.name
        read, write = os.pipe()
        try:
            self.process = subprocess.Popen(
                [str(directory / ".venv/bin/python"), str(directory / "worker.py")],
                cwd=directory,
                stdin=subprocess.PIPE,
                text=True,
                pass_fds=(write,),
                env={**os.environ, "WORKER_REPLY_FD": str(write)},
            )
            os.close(write)
            self.replies = os.fdopen(read, "r")
            ready = self.replies.readline()
            if not ready:
                raise RuntimeError("worker exited during start (see the terminal)")
            self.state = "ready"
        except Exception as error:
            self.state, self.error = "failed", str(error)

    def request(self, payload: dict) -> dict:
        if self.state != "ready":
            raise RuntimeError(f"{ENGINES[self.name]} は{'準備中' if self.state == 'starting' else '起動に失敗'}です")
        with self.lock:
            self.process.stdin.write(json.dumps(payload, ensure_ascii=False) + "\n")
            self.process.stdin.flush()
            line = self.replies.readline()
        if not line:
            self.state = "failed"
            raise RuntimeError(f"{ENGINES[self.name]} が止まりました（ターミナルを見てください）")
        reply = json.loads(line)
        if not reply.get("ok"):
            raise RuntimeError(reply.get("error", "unknown error"))
        return reply


def describe(path: Path) -> dict:
    audio, rate = sf.read(path, dtype="float32")
    peak = float(np.max(np.abs(audio))) if len(audio) else 0.0
    return {"seconds": round(len(audio) / rate, 3), "peak_dbfs": round(20 * np.log10(max(peak, 1e-9)), 1)}


class App:
    def __init__(self) -> None:
        self.workers = {name: Worker(name) for name in ENGINES}
        self.katakana = Katakana()
        self.transcribe = Transcriber()
        self.references: dict[str, dict] = {}
        self.lock = threading.Lock()
        self.pool = ThreadPoolExecutor(max_workers=len(ENGINES))

    def add_reference(self, audio: np.ndarray, label: str, transcript: str | None, language: str = "ja") -> dict:
        if len(audio) < REFERENCE_RATE:
            raise ValueError("1 秒より短い音は使えません")
        if len(audio) > MAX_REFERENCE_SECONDS * REFERENCE_RATE:
            raise ValueError(f"参照の声は {MAX_REFERENCE_SECONDS} 秒までにしてください（5〜15 秒が目安）")
        reference_id = "ref-" + hashlib.sha256(audio.tobytes()).hexdigest()[:12]
        if reference_id not in self.references:
            AUDIO_DIR.mkdir(parents=True, exist_ok=True)
            path = AUDIO_DIR / f"{reference_id}.wav"
            sf.write(path, np.clip(audio, -1, 1), REFERENCE_RATE, subtype="PCM_16")
            if transcript is None:
                started = time.perf_counter()
                transcript = self.transcribe(resample_16k(audio, REFERENCE_RATE), language)
                print(f"[whisper] {label}: {time.perf_counter() - started:.1f}s")
            self.references[reference_id] = {
                "id": reference_id,
                "label": label,
                "path": str(path),
                "url": f"/audio/{path.name}",
                "transcript": transcript,
                "seconds": round(len(audio) / REFERENCE_RATE, 2),
            }
        return self.public(self.references[reference_id])

    @staticmethod
    def public(reference: dict) -> dict:
        return {key: value for key, value in reference.items() if key != "path"}

    def add_samples(self, labs_root: Path) -> None:
        path = labs_root / SAMPLE_ASSET
        if not path.exists():
            print(f"[warn] sample asset not found: {path} (run `mise run //:test-assets:download v1 labs v1`)")
            return
        audio = decode(path.read_bytes(), ".mp3", REFERENCE_RATE)
        for label, segments, transcript in SAMPLE_SPEAKERS:
            pieces = [audio[int(start * REFERENCE_RATE) : int(end * REFERENCE_RATE)] for start, end in segments]
            self.add_reference(np.concatenate(pieces), label, transcript)

    def status(self) -> dict:
        return {name: {"label": ENGINES[name], "state": worker.state, "error": worker.error} for name, worker in self.workers.items()}

    def synthesize(self, request: dict) -> dict:
        reference = self.references.get(request.get("reference_id", ""))
        if reference is None:
            raise ValueError("参照の声を選んでください")
        text = str(request.get("text", "")).strip()
        if not text:
            raise ValueError("読ませる文を入れてください")
        if len(text) > 300:
            raise ValueError("文は 300 字まで")
        language = request.get("language", "ja")
        use_transcript = bool(request.get("use_transcript", True))
        reference_text = reference["transcript"] if use_transcript else ""
        engines = [name for name in request.get("engines", list(ENGINES)) if name in ENGINES]
        stem = f"{int(time.time() * 1000)}"

        def run(name: str) -> dict:
            engine_text, engine_reference_text = text, reference_text
            # Upstream: "for Japanese usage, you must translate it to katakana" (CosyVoice example.py).
            if name == "cosyvoice3" and language == "ja" and request.get("katakana", True):
                engine_text = self.katakana(text)
                engine_reference_text = self.katakana(reference_text) if reference_text else ""
            output = AUDIO_DIR / f"{stem}-{name}.wav"
            started = time.perf_counter()
            try:
                reply = self.workers[name].request(
                    {
                        "text": engine_text,
                        "language": language,
                        "reference_wav": reference["path"],
                        "reference_text": engine_reference_text,
                        "output_wav": str(output),
                        "model": request.get("qwen_model", "1.7B"),
                        "seed": int(request.get("seed", 0)),
                    }
                )
            except Exception as error:
                return {"engine": name, "label": ENGINES[name], "ok": False, "error": str(error)}
            wall = time.perf_counter() - started
            return {
                "engine": name,
                "label": ENGINES[name],
                "ok": True,
                "url": f"/audio/{output.name}",
                "model": reply["model"],
                "device": reply["device"],
                "mode": reply["mode"],
                "input_text": reply["input_text"],
                "seconds": round(reply["seconds"], 2),
                "generate_seconds": round(reply["timings"]["generate"], 2),
                "wall_seconds": round(wall, 2),
                "real_time_factor": round(reply["timings"]["generate"] / max(reply["seconds"], 1e-6), 2),
                "peak_dbfs": describe(output)["peak_dbfs"],
            }

        results = list(self.pool.map(run, engines))
        return {"text": text, "reference": self.public(reference), "results": results}


class Handler(BaseHTTPRequestHandler):
    app: App

    def log_message(self, format: str, *args) -> None:  # noqa: A002
        if not self.path.startswith("/api/status"):
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
        elif self.path == "/api/status":
            self.send_json(self.app.status())
        elif self.path == "/api/references":
            self.send_json([App.public(reference) for reference in self.app.references.values()])
        elif self.path.startswith("/audio/"):
            self.send_file(AUDIO_DIR / Path(unquote(self.path[len("/audio/") :])).name, "audio/wav")
        else:
            self.send_error(HTTPStatus.NOT_FOUND)

    def do_POST(self) -> None:  # noqa: N802
        try:
            if self.path == "/api/references":
                filename = unquote(self.headers.get("X-Filename", "upload"))
                audio = decode(self.read_body(), Path(filename).suffix.lower(), REFERENCE_RATE)
                self.send_json(self.app.add_reference(audio, filename, None, self.headers.get("X-Language", "ja")))
            elif self.path == "/api/transcript":
                body = json.loads(self.read_body())
                reference = self.app.references[body["id"]]
                reference["transcript"] = str(body["transcript"]).strip()
                self.send_json(App.public(reference))
            elif self.path == "/api/katakana":
                self.send_json({"katakana": self.app.katakana(json.loads(self.read_body())["text"])})
            elif self.path == "/api/synthesize":
                self.send_json(self.app.synthesize(json.loads(self.read_body())))
            else:
                self.send_error(HTTPStatus.NOT_FOUND)
        except (ValueError, KeyError) as error:
            self.send_json({"error": str(error)}, HTTPStatus.BAD_REQUEST)
        except Exception as error:
            self.send_json({"error": f"{type(error).__name__}: {error}"}, HTTPStatus.INTERNAL_SERVER_ERROR)
            raise


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8776)
    parser.add_argument("--no-browser", action="store_true")
    args = parser.parse_args()

    # Bind first so a busy port fails before the engines start loading.
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    app = App()
    app.add_samples(Path(os.environ.get("LABS_REPO_ROOT", LAB_DIR.parents[3])))
    Handler.app = app
    url = f"http://{args.host}:{args.port}/"
    print(f"[serve] {url} (the engines keep loading in the background)")
    if not args.no_browser:
        webbrowser.open(url)
    server.serve_forever()


if __name__ == "__main__":
    main()
