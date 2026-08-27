"""Measure what a live camera session reports once the model cannot keep up.

The file matrix answers whether a machine keeps up. This answers what happens
when it does not: whether the delay grows without bound, how much of the input
is discarded to hold it back, and whether the numbers the UI puts on screen are
honest while that happens.

Honesty is checked without sharing a clock with the server. Every result carries
the segment's end time on the stream and the lag behind the live edge, so for an
honest pair `end_s + lag_s` must equal this client's own elapsed time when the
result arrives. A constant offset is the connection setup; a growing gap is time
the server has lost track of.

The client stands in for the browser: it sends one JPEG per frame over the same
websocket at the same requested rate, so the server cannot tell the difference.
"""

from __future__ import annotations

import argparse
import asyncio
import io
import json
import statistics
import time
from pathlib import Path

import websockets
from PIL import Image, ImageDraw


def frame(index: int, seconds: float, size: tuple[int, int]) -> bytes:
    """Draw one frame carrying its own timestamp.

    The moving bar gives the codec real motion to find, and the burned-in clock
    lets a human open a recorded segment and read which moment it looked at.
    """
    width, height = size
    image = Image.new("RGB", size, (14, 18, 26))
    draw = ImageDraw.Draw(image)
    bar = width // 8
    draw.rectangle(
        [(seconds * width / 8) % (width - bar), height * 0.42,
         (seconds * width / 8) % (width - bar) + bar, height * 0.58],
        fill=(220, 90, 40),
    )
    draw.text((20, 20), f"t={seconds:7.2f}s  frame={index:04d}", fill=(240, 240, 240))
    buffer = io.BytesIO()
    image.save(buffer, format="JPEG", quality=80)
    return buffer.getvalue()


async def capture(url: str, settings: dict, fps: float, duration: float,
                  size: tuple[int, int]) -> list[dict]:
    messages: list[dict] = []
    origin: float | None = None

    async with websockets.connect(url, max_size=None) as socket:
        await socket.recv()
        await socket.send(json.dumps({"action": "start_camera", **settings}))

        async def reader() -> None:
            async for raw in socket:
                if isinstance(raw, bytes):
                    continue
                message = json.loads(raw)
                message["client_elapsed_s"] = (
                    None if origin is None else time.monotonic() - origin
                )
                messages.append(message)

        task = asyncio.create_task(reader())
        # The browser only starts capturing once the model is ready. Sending
        # during the load would fill the queue with frames the run never sees.
        while not any(m.get("type") == "model" and m.get("state") == "ready"
                      for m in messages):
            if task.done():
                task.result()
            await asyncio.sleep(0.25)

        origin = time.monotonic()
        index = 0
        while (elapsed := time.monotonic() - origin) < duration:
            await socket.send(frame(index, elapsed, size))
            index += 1
            await asyncio.sleep(max(0.0, index / fps - (time.monotonic() - origin)))

        await socket.send(json.dumps({"action": "stop"}))
        await asyncio.sleep(2.0)
        task.cancel()

    return messages


def summarize(messages: list[dict], settings: dict, fps: float) -> dict:
    results = [m for m in messages if m.get("type") == "result"]
    if not results:
        return {"segments": 0, "note": "no segment completed"}

    # Steady state only: the first segments run against an empty queue and are
    # faster than the machine can sustain, so averaging them in would flatter it.
    steady = results[len(results) // 2:]
    gaps = [
        m["client_elapsed_s"] - (m["result"]["end_s"] + m["lag_s"]) for m in results
    ]
    spans = [m["result"]["end_s"] - m["result"]["start_s"] for m in steady]
    last = results[-1]
    return {
        "segments": len(results),
        "frames_received": last.get("received"),
        "frames_dropped": last.get("dropped"),
        "dropped_share": (
            None if not last.get("received")
            else round(last["dropped"] / last["received"], 3)
        ),
        "steady_lag_s": {
            "median": round(statistics.median(m["lag_s"] for m in steady), 3),
            "min": round(min(m["lag_s"] for m in steady), 3),
            "max": round(max(m["lag_s"] for m in steady), 3),
        },
        "steady_window_span_s": {
            "median": round(statistics.median(spans), 2),
            "requested": settings["window_s"],
        },
        "steady_effective_fps": {
            "median": round(statistics.median(
                m["effective_fps"] for m in steady if m.get("effective_fps")
            ), 2),
            "requested": fps,
        },
        # A constant offset is connection setup. A gap that grows is the server
        # under-reporting how far behind it has fallen.
        "honesty_gap_s": {
            "median": round(statistics.median(gaps), 3),
            "min": round(min(gaps), 3),
            "max": round(max(gaps), 3),
            "drift": round(max(gaps) - min(gaps), 3),
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="ws://127.0.0.1:8000/ws")
    parser.add_argument("--backend", choices=("frames", "codec"), default="frames")
    parser.add_argument("--segment-sec", type=float, default=1.0)
    parser.add_argument("--window-sec", type=float, default=4.0)
    parser.add_argument("--target-fps", type=float, default=2.0)
    parser.add_argument("--num-frames", type=int, default=16)
    parser.add_argument("--max-new-tokens", type=int, default=2)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--duration", type=float, default=120.0)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    settings = {
        "backend": args.backend,
        "analysis_mode": "describe",
        "question": "Describe what is happening. Focus on changes and motion.",
        "segment_s": args.segment_sec,
        "window_s": args.window_sec,
        "target_fps": args.target_fps,
        "num_frames": args.num_frames,
        "gate_threshold": 0.0,
        "max_new_tokens": args.max_new_tokens,
    }
    size = (args.width, args.height)
    messages = asyncio.run(
        capture(args.url, settings, args.target_fps, args.duration, size)
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    raw = args.output.with_suffix(".jsonl")
    with raw.open("w") as handle:
        for message in messages:
            handle.write(json.dumps(message) + "\n")

    report = {
        "settings": settings,
        "frame_size": f"{args.width}x{args.height}",
        "duration_s": args.duration,
        "raw": raw.name,
        "summary": summarize(messages, settings, args.target_fps),
    }
    rendered = json.dumps(report, indent=2)
    args.output.write_text(rendered + "\n")
    print(rendered)


if __name__ == "__main__":
    main()
