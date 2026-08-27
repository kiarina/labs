"""Ask whether the streaming gate survives the camera capture path.

The Web UI's camera mode is frames-only, where the gate sits at p ~= 0.001 and is
useless. The reason is not that codec cannot work on camera input: the browser
sends independent JPEG stills and the server rebuilds them with an MPEG-4 Part 2
writer, which the official cv-preinfer cannot parse. Re-encoding the same stills
as H.264 does parse.

That leaves the real question. Codec-native processing reads bit cost out of a
compressed stream. If we manufacture that stream by re-encoding stills sampled at
2-8 fps, is the gate signal still there, or was it a property of the original
24 fps encode?

This reproduces the camera path exactly — decode, resize to the UI's 768 px
canvas width, JPEG at quality 84, re-encode — and compares the resulting gate
probability against the same clip fed through the native file path.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import time

import cv2
import mlx.core as mx
import numpy as np

from mage_vl_mlx.realtime import RealtimeSession, extract_subclip, video_duration

CANVAS_MAX_WIDTH = 768  # examples/realtime_web_ui/static/app.js
JPEG_QUALITY = 84


def camera_stills(source: Path, start_s: float, end_s: float, fps: float) -> list[bytes]:
    """The JPEG stills the browser would have sent for this window."""
    capture = cv2.VideoCapture(str(source))
    source_fps = capture.get(cv2.CAP_PROP_FPS) or 24.0
    stills = []
    stamp = start_s
    while stamp < end_s - 1e-6:
        capture.set(cv2.CAP_PROP_POS_FRAMES, int(round(stamp * source_fps)))
        ok, frame = capture.read()
        if not ok:
            break
        height, width = frame.shape[:2]
        scale = min(1.0, CANVAS_MAX_WIDTH / width)
        target = (
            max(2, int(round(width * scale / 2)) * 2),
            max(2, int(round(height * scale / 2)) * 2),
        )
        frame = cv2.resize(frame, target)
        ok, buffer = cv2.imencode(
            ".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, JPEG_QUALITY]
        )
        if ok:
            stills.append(buffer.tobytes())
        stamp += 1.0 / fps
    capture.release()
    return stills


def write_clip(stills: list[bytes], fps: float, output: Path, encoder: str) -> Path:
    frames = [
        cv2.imdecode(np.frombuffer(b, np.uint8), cv2.IMREAD_COLOR) for b in stills
    ]
    frames = [f for f in frames if f is not None]
    if not frames:
        raise ValueError("no frames")
    height, width = frames[0].shape[:2]
    if encoder == "mp4v":
        writer = cv2.VideoWriter(
            str(output), cv2.VideoWriter_fourcc(*"mp4v"), fps, (width, height)
        )
        for frame in frames:
            writer.write(frame)
        writer.release()
        return output
    # H.264 through ffmpeg, matching what extract_subclip already produces for
    # the file path.
    raw = output.with_suffix(".raw")
    with raw.open("wb") as sink:
        for frame in frames:
            sink.write(frame.tobytes())
    subprocess.run(
        [
            "ffmpeg", "-y", "-loglevel", "error",
            "-f", "rawvideo", "-pix_fmt", "bgr24",
            "-s", f"{width}x{height}", "-r", str(fps), "-i", str(raw),
            "-c:v", "libx264", "-pix_fmt", "yuv420p", "-an", str(output),
        ],
        check=True,
    )
    raw.unlink(missing_ok=True)
    return output


def probe(session, clip: Path, question: str, start_s: float, end_s: float) -> dict:
    session.reset()
    started = time.perf_counter()
    result = session.process_segment(clip, question, start_s=start_s, end_s=end_s)
    return {
        "probability": result.probability,
        "text": (result.text or "").strip(),
        "work_s": time.perf_counter() - started,
        "preprocess_s": result.metrics.preprocess_s,
        "vision_s": result.metrics.vision_s,
        "gate_s": result.metrics.gate_s,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--weights", required=True, type=Path)
    parser.add_argument("--clips", nargs="+", required=True, type=Path)
    parser.add_argument("--capture-fps", nargs="+", type=float, default=[2, 4, 8])
    parser.add_argument("--window-sec", type=float, default=4.0)
    parser.add_argument("--question", default="Describe what is happening.")
    parser.add_argument(
        "--gate-threshold",
        type=float,
        default=1.0,
        help="1.0 measures the gate without paying for generation",
    )
    parser.add_argument("--max-new-tokens", type=int, default=16)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()

    sessions = {}
    for backend in ("frames", "codec"):
        template = RealtimeSession.from_pretrained(
            args.weights,
            model_dtype=mx.bfloat16,
            gate_dtype=mx.float32,
            video_backend=backend,
        )
        sessions[backend] = lambda t=template, b=backend: RealtimeSession(
            t.model, t.gate, t.prompt_builder,
            model_dtype=mx.bfloat16, gate_dtype=mx.float32, video_backend=b,
            num_frames=16, target_fps=2.0,
            gate_threshold=args.gate_threshold,
            max_new_tokens=args.max_new_tokens,
        )

    rows = []
    for clip_path in args.clips:
        duration = video_duration(clip_path)
        windows = []
        end_s = args.window_sec
        while end_s <= duration + 1e-6:
            windows.append((end_s - args.window_sec, end_s))
            end_s += args.window_sec
        with tempfile.TemporaryDirectory(dir=clip_path.resolve().parent) as directory:
            work = Path(directory)
            for start_s, window_end in windows:
                # cv-preinfer caches by resolved video path, so every window
                # needs its own filename or the first window's assets are reused.
                tag = f"{start_s:g}-{window_end:g}"
                native = work / f"native-{tag}.mp4"
                extract_subclip(clip_path, start_s, window_end - start_s, native)
                for backend in ("frames", "codec"):
                    try:
                        row = probe(
                            sessions[backend](), native, args.question,
                            start_s, window_end,
                        )
                    except Exception as error:
                        row = {"error": f"{type(error).__name__}: {error}"[:300]}
                    rows.append({
                        "clip": clip_path.name, "window": [start_s, window_end],
                        "path": "native-file", "backend": backend,
                        "capture_fps": None, "encoder": "libx264", **row,
                    })

                for capture_fps in args.capture_fps:
                    stills = camera_stills(clip_path, start_s, window_end, capture_fps)
                    for encoder in ("mp4v", "h264"):
                        simulated = work / f"cam-{tag}-{capture_fps:g}-{encoder}.mp4"
                        try:
                            write_clip(stills, capture_fps, simulated, encoder)
                        except Exception as error:
                            rows.append({
                                "clip": clip_path.name, "window": [start_s, window_end],
                                "path": "camera-simulated", "backend": None,
                                "capture_fps": capture_fps, "encoder": encoder,
                                "frames": len(stills),
                                "error": f"encode: {type(error).__name__}: {error}"[:200],
                            })
                            continue
                        for backend in ("frames", "codec"):
                            try:
                                row = probe(
                                    sessions[backend](), simulated, args.question,
                                    start_s, window_end,
                                )
                            except Exception as error:
                                row = {"error": f"{type(error).__name__}: {error}"[:300]}
                            rows.append({
                                "clip": clip_path.name,
                                "window": [start_s, window_end],
                                "path": "camera-simulated", "backend": backend,
                                "capture_fps": capture_fps, "encoder": encoder,
                                "frames": len(stills), **row,
                            })
                print(f"done {clip_path.name} {start_s}-{window_end}", file=sys.stderr, flush=True)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps({"rows": rows}, indent=2) + "\n")
    print(f"wrote {args.output}")


if __name__ == "__main__":
    main()
