from __future__ import annotations

import argparse
import base64
import io
import json
import os
import tempfile
import threading
import time
import webbrowser
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

from main import (
    INFERENCE_STEPS,
    FIRST_CHUNK_SAMPLES,
    SAMPLE_RATE,
    SEED,
    STEADY_CHUNK_SAMPLES,
    TARGET_SEGMENTS,
    SOURCE_SEGMENTS,
    concatenate_segments,
    decode_audio,
    ensure_meanvc_source,
    ensure_models,
    ensure_s3prl,
    load_runner_class,
    streaming_chunks,
)


MAX_REQUEST_BYTES = 64 * 1024 * 1024
MAX_AUDIO_SECONDS = 30
MIN_TARGET_SECONDS = 1


class DemoEngine:
    def __init__(self, lab_dir: Path, sample_audio: Path) -> None:
        self.lab_dir = lab_dir
        self.sample_audio = sample_audio
        self.lock = threading.Lock()
        self.runner = None
        self.state = "cold"
        self.error: str | None = None
        self.live_active = False
        self.live_chunk_index = 0

    def sample_pair(self) -> tuple[np.ndarray, np.ndarray]:
        audio = decode_audio(self.sample_audio)
        return (
            concatenate_segments(audio, SOURCE_SEGMENTS),
            concatenate_segments(audio, TARGET_SEGMENTS),
        )

    def _load(self, initial_target: np.ndarray) -> float:
        if self.runner is not None:
            return 0.0
        self.state = "loading"
        started = time.perf_counter()
        try:
            source_dir = ensure_meanvc_source(self.lab_dir)
            s3prl_source_dir, s3prl_wavlm_path = ensure_s3prl(self.lab_dir)
            ensure_models(self.lab_dir, source_dir)
            with tempfile.NamedTemporaryFile(suffix=".wav") as target_file:
                sf.write(target_file.name, initial_target, SAMPLE_RATE, subtype="PCM_16")
                previous_cwd = Path.cwd()
                try:
                    os.chdir(source_dir)
                    torch.set_num_threads(1)
                    torch.manual_seed(SEED)
                    runner_class = load_runner_class(
                        source_dir, s3prl_source_dir, s3prl_wavlm_path
                    )
                    self.runner = runner_class(
                        target_file.name, steps=INFERENCE_STEPS
                    )
                finally:
                    os.chdir(previous_cwd)
            self.state = "ready"
            self.error = None
        except Exception as exception:
            self.state = "error"
            self.error = str(exception)
            raise
        return time.perf_counter() - started

    def _set_target(self, target: np.ndarray) -> None:
        waveform = torch.from_numpy(target).unsqueeze(0)
        with torch.no_grad():
            self.runner.vc_spk_emb = self.runner.sv_model(waveform)
            self.runner.vc_prompt_mel = self.runner.mel_extract(waveform).transpose(
                1, 2
            )

    def convert(self, source: np.ndarray, target: np.ndarray) -> tuple[np.ndarray, dict]:
        validate_audio(source, "source")
        validate_audio(target, "target", minimum_seconds=MIN_TARGET_SECONDS)
        with self.lock:
            model_load_seconds = self._load(target)
            self._set_target(target)
            torch.manual_seed(SEED)
            self.runner.init_cache()
            outputs = []
            elapsed = []
            for chunk in streaming_chunks(source):
                started = time.perf_counter()
                outputs.append(
                    np.asarray(self.runner.inference_one_chunk(chunk), dtype=np.float32)
                )
                elapsed.append(time.perf_counter() - started)
        converted = np.concatenate(outputs)
        metrics = {
            "source_seconds": len(source) / SAMPLE_RATE,
            "target_seconds": len(target) / SAMPLE_RATE,
            "converted_seconds": len(converted) / SAMPLE_RATE,
            "chunks": len(elapsed),
            "inference_seconds": sum(elapsed),
            "realtime_factor": sum(elapsed) / (len(source) / SAMPLE_RATE),
            "chunk_p50_ms": float(np.percentile(elapsed, 50) * 1000),
            "chunk_p95_ms": float(np.percentile(elapsed, 95) * 1000),
            "model_load_seconds": model_load_seconds,
        }
        return converted, metrics

    def start_live(self, target: np.ndarray) -> dict:
        validate_audio(target, "target", minimum_seconds=MIN_TARGET_SECONDS)
        with self.lock:
            model_load_seconds = self._load(target)
            self._set_target(target)
            torch.manual_seed(SEED)
            self.runner.init_cache()
            self.live_active = True
            self.live_chunk_index = 0
        return {
            "model_load_seconds": model_load_seconds,
            "first_chunk_samples": FIRST_CHUNK_SAMPLES,
            "steady_chunk_samples": STEADY_CHUNK_SAMPLES,
            "sample_rate": SAMPLE_RATE,
        }

    def convert_live_chunk(self, samples: np.ndarray) -> tuple[np.ndarray, dict]:
        with self.lock:
            if not self.live_active:
                raise ValueError("live session is not active")
            expected = (
                FIRST_CHUNK_SAMPLES
                if self.live_chunk_index == 0
                else STEADY_CHUNK_SAMPLES
            )
            if len(samples) != expected:
                raise ValueError(
                    f"live chunk must contain {expected} samples, got {len(samples)}"
                )
            started = time.perf_counter()
            output = np.asarray(
                self.runner.inference_one_chunk(samples.astype(np.float32)),
                dtype=np.float32,
            )
            elapsed = time.perf_counter() - started
            self.live_chunk_index += 1
            index = self.live_chunk_index
        return output, {
            "index": index,
            "elapsed_ms": elapsed * 1000,
            "input_ms": len(samples) / SAMPLE_RATE * 1000,
        }

    def stop_live(self) -> None:
        with self.lock:
            self.live_active = False
            self.live_chunk_index = 0


def validate_audio(
    samples: np.ndarray, label: str, minimum_seconds: float = 0.1
) -> None:
    duration = len(samples) / SAMPLE_RATE
    if duration < minimum_seconds:
        raise ValueError(f"{label} audio must be at least {minimum_seconds:.1f} seconds")
    if duration > MAX_AUDIO_SECONDS:
        raise ValueError(f"{label} audio must be at most {MAX_AUDIO_SECONDS} seconds")
    if not np.all(np.isfinite(samples)):
        raise ValueError(f"{label} audio contains invalid samples")


def decode_data_url(value: str, label: str) -> np.ndarray:
    if not isinstance(value, str) or "," not in value:
        raise ValueError(f"missing {label} audio")
    header, encoded = value.split(",", 1)
    if not header.startswith("data:audio/"):
        raise ValueError(f"{label} must be an audio file")
    payload = base64.b64decode(encoded, validate=True)
    if not payload:
        raise ValueError(f"empty {label} audio")
    with tempfile.NamedTemporaryFile(suffix=".audio") as temporary:
        temporary.write(payload)
        temporary.flush()
        return decode_audio(Path(temporary.name))


def wav_data_url(samples: np.ndarray) -> str:
    buffer = io.BytesIO()
    sf.write(buffer, samples, SAMPLE_RATE, format="WAV", subtype="PCM_16")
    encoded = base64.b64encode(buffer.getvalue()).decode("ascii")
    return f"data:audio/wav;base64,{encoded}"


def decode_float32(value: str) -> np.ndarray:
    try:
        payload = base64.b64decode(value, validate=True)
    except (ValueError, TypeError) as exception:
        raise ValueError("invalid live PCM payload") from exception
    if len(payload) % 4:
        raise ValueError("live PCM payload is not float32 aligned")
    return np.frombuffer(payload, dtype="<f4").copy()


def encode_float32(samples: np.ndarray) -> str:
    return base64.b64encode(samples.astype("<f4").tobytes()).decode("ascii")


def make_handler(engine: DemoEngine, index_html: bytes):
    class Handler(BaseHTTPRequestHandler):
        server_version = "MeanVCDemo/1.0"

        def log_message(self, format: str, *args) -> None:
            print(f"{self.address_string()} - {format % args}")

        def send_bytes(self, status: int, content_type: str, body: bytes) -> None:
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def send_json(self, status: int, payload: dict) -> None:
            body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            self.send_bytes(status, "application/json; charset=utf-8", body)

        def do_GET(self) -> None:
            if self.path == "/":
                self.send_bytes(HTTPStatus.OK, "text/html; charset=utf-8", index_html)
            elif self.path == "/api/status":
                self.send_json(
                    HTTPStatus.OK,
                    {"state": engine.state, "error": engine.error},
                )
            else:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})

        def do_POST(self) -> None:
            allowed_paths = {
                "/api/convert",
                "/api/live/start",
                "/api/live/chunk",
                "/api/live/stop",
            }
            if self.path not in allowed_paths:
                self.send_json(HTTPStatus.NOT_FOUND, {"error": "not found"})
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length <= 0 or length > MAX_REQUEST_BYTES:
                    raise ValueError("request is empty or too large")
                request = json.loads(self.rfile.read(length))
                if self.path == "/api/live/start":
                    target = decode_data_url(request.get("target", ""), "target")
                    self.send_json(HTTPStatus.OK, engine.start_live(target))
                elif self.path == "/api/live/chunk":
                    output, metrics = engine.convert_live_chunk(
                        decode_float32(request.get("samples", ""))
                    )
                    self.send_json(
                        HTTPStatus.OK,
                        {"samples": encode_float32(output), "metrics": metrics},
                    )
                elif self.path == "/api/live/stop":
                    engine.stop_live()
                    self.send_json(HTTPStatus.OK, {"stopped": True})
                else:
                    if request.get("sample"):
                        source, target = engine.sample_pair()
                    else:
                        source = decode_data_url(
                            request.get("source", ""), "source"
                        )
                        target = decode_data_url(
                            request.get("target", ""), "target"
                        )
                    converted, metrics = engine.convert(source, target)
                    self.send_json(
                        HTTPStatus.OK,
                        {"audio": wav_data_url(converted), "metrics": metrics},
                    )
            except (ValueError, json.JSONDecodeError) as exception:
                self.send_json(HTTPStatus.BAD_REQUEST, {"error": str(exception)})
            except Exception as exception:
                engine.error = str(exception)
                self.send_json(
                    HTTPStatus.INTERNAL_SERVER_ERROR,
                    {"error": f"conversion failed: {exception}"},
                )

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description="MeanVC local demo server")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--no-open", action="store_true")
    args = parser.parse_args()

    lab_dir = Path(__file__).resolve().parent
    repo_root = Path(
        os.environ.get("LABS_REPO_ROOT", lab_dir.parents[3])
    ).resolve()
    sample_audio = repo_root / "tests/assets/mp3/conversation_2speaker_14s_16k.mp3"
    if not sample_audio.exists():
        raise FileNotFoundError(
            "sample asset is missing; start the demo with `mise run demo`"
        )
    index_html = (lab_dir / "web/index.html").read_bytes()
    engine = DemoEngine(lab_dir, sample_audio)
    server = ThreadingHTTPServer(
        (args.host, args.port), make_handler(engine, index_html)
    )
    url = f"http://{args.host}:{args.port}"
    print(f"MeanVC demo: {url}")
    print("Press Ctrl-C to stop")
    if not args.no_open:
        threading.Timer(0.5, webbrowser.open, args=(url,)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping demo")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
