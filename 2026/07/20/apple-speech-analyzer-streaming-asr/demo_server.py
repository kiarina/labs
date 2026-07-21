#!/usr/bin/env python3
"""Serve the microphone UI and bridge browser PCM to SpeechAnalyzer."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import http.server
import json
import math
import threading
import webbrowser
from array import array
from pathlib import Path

from websockets.asyncio.server import ServerConnection, serve


LAB_DIR = Path(__file__).resolve().parent
WEB_DIR = LAB_DIR / "web"
DEFAULT_BINARY = LAB_DIR / ".build" / "release" / "speech-analyzer"
ANALYZER_SAMPLE_RATE = 16_000
ANALYZER_CHUNK_BYTES = ANALYZER_SAMPLE_RATE // 10 * 4


class StreamingLinearResampler:
    """Continuously resample little-endian Float32 mono PCM across messages."""

    def __init__(self, source_rate: int, target_rate: int = ANALYZER_SAMPLE_RATE):
        self.ratio = source_rate / target_rate
        self.samples: list[float] = []
        self.position = 0.0
        self.byte_remainder = bytearray()

    def feed(self, data: bytes) -> bytes:
        self.byte_remainder.extend(data)
        complete_bytes = len(self.byte_remainder) - len(self.byte_remainder) % 4
        if not complete_bytes:
            return b""

        values = array("f")
        values.frombytes(self.byte_remainder[:complete_bytes])
        del self.byte_remainder[:complete_bytes]
        self.samples.extend(values)
        return self._produce(allow_last_sample=False)

    def flush(self) -> bytes:
        output = self._produce(allow_last_sample=True)
        self.samples.clear()
        self.byte_remainder.clear()
        self.position = 0.0
        return output

    def _produce(self, *, allow_last_sample: bool) -> bytes:
        output = array("f")
        limit = len(self.samples) if allow_last_sample else len(self.samples) - 1
        while self.position < limit:
            lower = int(self.position)
            upper = min(lower + 1, len(self.samples) - 1)
            fraction = self.position - lower
            output.append(
                self.samples[lower] * (1 - fraction)
                + self.samples[upper] * fraction
            )
            self.position += self.ratio

        consumed = min(int(self.position), len(self.samples))
        if consumed:
            del self.samples[:consumed]
            self.position -= consumed
        return output.tobytes()


class AudioStats:
    def __init__(self, sample_rate: int = ANALYZER_SAMPLE_RATE):
        self.sample_rate = sample_rate
        self.total_samples = 0
        self.window_samples = 0
        self.sum_squares = 0.0
        self.peak = 0.0

    def add(self, data: bytes) -> dict[str, float] | None:
        values = array("f")
        values.frombytes(data)
        for sample in values:
            if not math.isfinite(sample):
                continue
            self.sum_squares += sample * sample
            self.peak = max(self.peak, abs(sample))
            self.window_samples += 1
        self.total_samples += len(values)
        if self.window_samples < self.sample_rate:
            return None

        rms = math.sqrt(self.sum_squares / self.window_samples)
        result = {
            "audioSeconds": self.total_samples / self.sample_rate,
            "rmsDbfs": 20 * math.log10(max(rms, 1e-8)),
            "peak": self.peak,
        }
        self.window_samples = 0
        self.sum_squares = 0.0
        self.peak = 0.0
        return result


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, format: str, *args: object) -> None:
        return


def start_http_server(host: str, port: int) -> http.server.ThreadingHTTPServer:
    handler = lambda *args, **kwargs: QuietHandler(  # noqa: E731
        *args, directory=str(WEB_DIR), **kwargs
    )
    server = http.server.ThreadingHTTPServer((host, port), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


async def relay_stderr(process: asyncio.subprocess.Process) -> None:
    assert process.stderr
    while line := await process.stderr.readline():
        print(f"[speech-analyzer] {line.decode().rstrip()}")


async def relay_results(
    process: asyncio.subprocess.Process,
    websocket: ServerConnection,
) -> None:
    assert process.stdout
    while line := await process.stdout.readline():
        await websocket.send(line.decode().rstrip())


async def microphone_session(
    websocket: ServerConnection,
    binary: Path,
) -> None:
    process: asyncio.subprocess.Process | None = None
    result_task: asyncio.Task[None] | None = None
    stderr_task: asyncio.Task[None] | None = None
    try:
        first = await websocket.recv()
        if not isinstance(first, str):
            raise ValueError("the first WebSocket message must be JSON")
        config = json.loads(first)
        source_sample_rate = int(config.get("sampleRate", ANALYZER_SAMPLE_RATE))
        if not 8_000 <= source_sample_rate <= 192_000:
            raise ValueError(f"unsupported sample rate: {source_sample_rate}")
        resampler = StreamingLinearResampler(source_sample_rate)
        audio_stats = AudioStats()
        pending_pcm = bytearray()
        print(
            f"[bridge] {source_sample_rate} Hz Float32 -> "
            f"{ANALYZER_SAMPLE_RATE} Hz Float32"
        )

        process = await asyncio.create_subprocess_exec(
            str(binary),
            "stream",
            "--sample-rate",
            str(ANALYZER_SAMPLE_RATE),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        result_task = asyncio.create_task(relay_results(process, websocket))
        stderr_task = asyncio.create_task(relay_stderr(process))
        assert process.stdin

        async for message in websocket:
            if isinstance(message, bytes):
                converted = resampler.feed(message)
                pending_pcm.extend(converted)
                if stats := audio_stats.add(converted):
                    await websocket.send(json.dumps({"type": "audio-stats", **stats}))
                while len(pending_pcm) >= ANALYZER_CHUNK_BYTES:
                    process.stdin.write(pending_pcm[:ANALYZER_CHUNK_BYTES])
                    del pending_pcm[:ANALYZER_CHUNK_BYTES]
                    await process.stdin.drain()
                continue
            payload = json.loads(message)
            if payload.get("type") == "stop":
                break

        pending_pcm.extend(resampler.flush())
        if pending_pcm:
            process.stdin.write(pending_pcm)
            await process.stdin.drain()

        process.stdin.close()
        await process.stdin.wait_closed()
        await process.wait()
        if result_task:
            await result_task
        if process.returncode:
            await websocket.send(json.dumps({
                "type": "error",
                "message": f"speech-analyzer exited with {process.returncode}",
            }))
    except Exception as error:
        with contextlib.suppress(Exception):
            await websocket.send(json.dumps({"type": "error", "message": str(error)}))
    finally:
        for task in (result_task, stderr_task):
            if task and not task.done():
                task.cancel()
        if process and process.returncode is None:
            process.terminate()
            with contextlib.suppress(ProcessLookupError, asyncio.TimeoutError):
                await asyncio.wait_for(process.wait(), timeout=2)


async def run(args: argparse.Namespace) -> None:
    binary = Path(args.binary).resolve()
    if not binary.is_file():
        raise SystemExit(f"speech-analyzer binary not found: {binary}")

    http_server = start_http_server(args.host, args.http_port)
    url = f"http://{args.host}:{args.http_port}"
    print(f"Microphone UI: {url}")
    print(f"WebSocket: ws://{args.host}:{args.ws_port}")
    if not args.no_open:
        webbrowser.open(url)

    try:
        async with serve(
            lambda socket: microphone_session(socket, binary),
            args.host,
            args.ws_port,
            max_size=2**22,
            compression=None,
        ):
            await asyncio.Future()
    finally:
        http_server.shutdown()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--http-port", type=int, default=8000)
    parser.add_argument("--ws-port", type=int, default=8765)
    parser.add_argument("--binary", default=str(DEFAULT_BINARY))
    parser.add_argument("--no-open", action="store_true")
    return parser.parse_args()


if __name__ == "__main__":
    try:
        asyncio.run(run(parse_args()))
    except KeyboardInterrupt:
        pass
