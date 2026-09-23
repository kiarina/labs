"""Compare streaming-gate p(speak) across vision-tower and gate dtypes.

Every segment is preprocessed once, and the same preprocessed input is fed to
all four dtype combinations, so the only thing that differs between them is
the arithmetic precision:

    vision tower  x  gate
    float32          float32    reference ("f32/f32")
    bfloat16         bfloat16   everything in bfloat16 ("bf16/bf16")
    bfloat16         float32    the port's default deployment ("bf16/f32")
    float32          bfloat16   completes the 2x2 ("f32/bf16")

The gate reads the whole video as one causal stream and is sampled at each
segment boundary, the way the official inference_streaming.py and the port's
gate_stream.py do.
"""

from __future__ import annotations

import argparse
import importlib.metadata
import json
import platform
import shutil
import sys
import time
from pathlib import Path

import mlx.core as mx
import numpy as np


SHORT = {"float32": "f32", "bfloat16": "bf16"}


def speak_probabilities(logits: mx.array, boundaries: list[int]) -> list[float]:
    values = np.asarray(logits.astype(mx.float32))[0][[b - 1 for b in boundaries]]
    shifted = values.astype(np.float64) - values.max(axis=-1, keepdims=True)
    exp = np.exp(shifted)
    return (exp / exp.sum(axis=-1, keepdims=True))[:, 1].tolist()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port-dir", type=Path, required=True)
    parser.add_argument("--weights", type=Path, required=True)
    parser.add_argument("--video", type=Path, action="append", required=True)
    parser.add_argument("--segments", type=float, nargs="+", default=[1, 2, 4, 8])
    parser.add_argument("--repeats", type=int, default=2,
                        help="gate passes per dtype pair, to check determinism")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    sys.path.insert(0, str(args.port_dir.resolve() / "src"))
    from mage_vl_mlx.codec import preprocess_codec, run_cv_preinfer
    from mage_vl_mlx.model import MageVL
    from mage_vl_mlx.realtime import extract_subclip, video_duration
    from mage_vl_mlx.streaming import StreamMindGate
    from mage_vl_mlx.video import preprocess_video

    # Three ways into the gate. codec at the source rate is the official
    # default; codec resampled to 8 fps is what the Web UI does; frames at
    # 2 fps / 16 frames is the official frames default, kept as a control
    # because it scores far from any threshold.
    protocols = {
        "codec-source": {"backend": "codec", "fps": None},
        "codec-8fps": {"backend": "codec", "fps": 8.0},
        "frames-2fps": {"backend": "frames", "fps": None},
    }

    work = args.output.parent / "work"
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    codec_cache = work / "codec-cache"

    # 1. Preprocess every segment once. Subclips are written next to the
    # output (not the system temp) because Docker cannot see /var/folders.
    streams = []
    for video in args.video:
        duration = video_duration(video)
        for protocol, spec in protocols.items():
            for segment_sec in args.segments:
                segments = []
                start = 0.0
                while start < duration - 1e-3:
                    end = min(duration, start + segment_sec)
                    clip = extract_subclip(
                        video, start, end - start,
                        work / f"{video.stem}_{protocol}_{segment_sec:g}_{int(start * 1000):06d}.mp4",
                        fps=spec["fps"],
                    )
                    try:
                        if spec["backend"] == "codec":
                            processed = preprocess_codec(
                                run_cv_preinfer(clip, cache_root=codec_cache))
                            units = int(processed["canvas_count"])
                        else:
                            processed = preprocess_video(
                                str(clip), max_frames=16, target_fps=2.0)
                            units = len(processed["frame_indices"])
                    except Exception as error:  # trailing sliver: skip like official
                        print(f"skip {video.stem} {protocol} {segment_sec:g}s "
                              f"t={start:.2f}: {type(error).__name__}", flush=True)
                        start = end
                        continue
                    segments.append({
                        "start": round(start, 3), "end": round(end, 3), "units": units,
                        "pixel_values": np.asarray(processed["pixel_values"], dtype=np.float32),
                        "grid_thw": np.asarray(processed["grid_thw"]).astype(np.int32),
                        "patch_positions": np.asarray(processed["patch_positions"]).astype(np.int32),
                    })
                    start = end
                streams.append({"video": video.name, "protocol": protocol,
                                "segment_sec": segment_sec, "segments": segments})
                print(f"prep {video.stem} {protocol} {segment_sec:g}s "
                      f"-> {len(segments)} segments", flush=True)

    # 2. Vision tokens in bfloat16, then in float32 from the same weights.
    model = MageVL.from_pretrained(args.weights)
    mx.eval(model.parameters())
    for vision_dtype in ("bfloat16", "float32"):
        dtype = getattr(mx, vision_dtype)
        if dtype != mx.bfloat16:
            model.update(model.apply(lambda p: p.astype(dtype)))
            mx.eval(model.parameters())
        started = time.perf_counter()
        for stream in streams:
            for segment in stream["segments"]:
                tokens = model.vision_tokens(
                    mx.array(segment["pixel_values"]).astype(dtype),
                    mx.array(segment["grid_thw"]),
                    mx.array(segment["patch_positions"]),
                )
                mx.eval(tokens)
                segment[vision_dtype] = tokens
        print(f"vision {vision_dtype}: {time.perf_counter() - started:.1f}s", flush=True)
    del model
    mx.clear_cache()

    # 3. Gate over each stream under each dtype pair.
    gates = {}
    for gate_dtype in ("bfloat16", "float32"):
        gate = StreamMindGate()
        gate.load_weights(str(args.weights / "streammind_gate.safetensors"))
        if gate_dtype != "bfloat16":
            gate.update(gate.apply(lambda p: p.astype(mx.float32)))
        mx.eval(gate.parameters())
        gates[gate_dtype] = gate

    pairs = [("float32", "float32"), ("bfloat16", "bfloat16"),
             ("bfloat16", "float32"), ("float32", "bfloat16")]
    rows = []
    nondeterministic = 0
    for stream in streams:
        segments = stream["segments"]
        if not segments:
            continue
        boundaries = [int(b) for b in np.cumsum(
            [s["float32"].shape[1] for s in segments])]
        results = {}
        for vision_dtype, gate_dtype in pairs:
            key = f"{SHORT[vision_dtype]}/{SHORT[gate_dtype]}"
            passes = []
            for _ in range(args.repeats):
                sequence = mx.concatenate(
                    [s[vision_dtype].astype(getattr(mx, gate_dtype)) for s in segments],
                    axis=1)
                logits = gates[gate_dtype](sequence, response_positions=boundaries)
                mx.eval(logits)
                passes.append(speak_probabilities(logits, boundaries))
            if any(p != passes[0] for p in passes[1:]):
                nondeterministic += 1
                print(f"NONDETERMINISTIC {stream['video']} {stream['protocol']} "
                      f"{stream['segment_sec']:g}s {key}", flush=True)
            results[key] = passes[0]
        for index, segment in enumerate(segments):
            rows.append({
                "video": stream["video"], "protocol": stream["protocol"],
                "segment_sec": stream["segment_sec"], "index": index,
                "start": segment["start"], "end": segment["end"],
                "units": segment["units"],
                "tokens": int(segment["float32"].shape[1]),
                "p_speak": {key: round(values[index], 8) for key, values in results.items()},
            })

    args.output.write_text(json.dumps({
        "environment": {
            "machine": platform.machine(),
            "macos": platform.mac_ver()[0],
            "python": platform.python_version(),
            "mlx": importlib.metadata.version("mlx"),
        },
        "segments_sec": args.segments,
        "repeats": args.repeats,
        "nondeterministic_streams": nondeterministic,
        "rows": rows,
    }, indent=2))
    shutil.rmtree(work, ignore_errors=True)
    print(f"wrote {len(rows)} segment rows to {args.output}", flush=True)


if __name__ == "__main__":
    main()
