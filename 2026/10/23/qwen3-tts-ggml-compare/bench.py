"""Run one engine configuration over the sentences and write the audio and the timings.

Each configuration runs in its own process. One warm-up sentence runs first and is not counted.

Usage:
  uv run bench.py qwentts --talker 1.7b-base-Q8_0 [--device MTL0|CUDA0|CPU] [--xvector]
  uv run bench.py llama [--quant Q8_0]
  uv run bench.py mlx                       # Mac
  uv run --project windows bench.py pl      # Windows (CUDA)
"""

from __future__ import annotations

import argparse
import json
import platform
import time

import numpy as np
import soundfile as sf

from engines.common import LAB_DIR, SAMPLE_RATE, TEXTS, WARMUP_TEXT, footprint_gb, playback_stalls


def make_engine(args):
    if args.engine == "qwentts":
        from engines.qwentts_engine import Engine

        return Engine(args.talker, args.device, ref_text=not args.xvector)
    if args.engine == "llama":
        from engines.llama_engine import Engine

        return Engine(args.quant)
    if args.engine == "mlx":
        from engines.mlx_engine import Engine

        return Engine()
    import onnxruntime  # noqa: PLC0415

    onnxruntime.preload_dlls()
    from engines.pl_engine import Engine

    return Engine(cuda=True)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("engine", choices=["qwentts", "llama", "mlx", "pl"])
    parser.add_argument("--talker", default="1.7b-base-Q8_0")
    parser.add_argument("--device", default="")
    parser.add_argument("--xvector", action="store_true", help="qwentts: register the voice without its transcript")
    parser.add_argument("--quant", default="Q8_0")
    parser.add_argument("--seeds", type=int, nargs="*", default=[0])
    parser.add_argument("--texts", type=int, nargs="*")
    args = parser.parse_args()

    (LAB_DIR / "output").mkdir(exist_ok=True)
    engine = make_engine(args)
    started = time.perf_counter()
    engine.load()
    load = time.perf_counter() - started
    warm = engine.synthesize(WARMUP_TEXT, 0)
    print(f"{engine.name}: load {load:.1f}s, warm-up {warm.seconds:.2f}s", flush=True)

    out_dir = LAB_DIR / "output" / engine.name
    out_dir.mkdir(parents=True, exist_ok=True)
    runs = []
    try:
        for index in args.texts if args.texts is not None else range(len(TEXTS)):
            for seed in args.seeds:
                result = engine.synthesize(TEXTS[index], seed)
                seconds = len(result.audio) / SAMPLE_RATE
                wav = out_dir / f"t{index}-s{seed}.wav"
                sf.write(wav, np.clip(result.audio, -1.0, 1.0), SAMPLE_RATE, subtype="PCM_16")
                run = {
                    "text": index,
                    "seed": seed,
                    "wav": f"{out_dir.name}/{wav.name}",
                    "audio_seconds": round(seconds, 3),
                    "generate_seconds": round(result.seconds, 3),
                    "rtf": round(result.seconds / seconds, 3) if seconds else None,
                    "first_audio_seconds": round(result.arrivals[0][0], 3) if result.arrivals else None,
                    "stall_seconds": round(playback_stalls(result.arrivals), 3) if result.arrivals else None,
                    "frames": result.frames,
                    **result.extra,
                }
                runs.append(run)
                print(
                    f"  t{index} s{seed}: {seconds:.2f}s audio in {result.seconds:.2f}s (RTF {run['rtf']}), "
                    f"first {run['first_audio_seconds']}s, stalls {run['stall_seconds']}s",
                    flush=True,
                )
        report = {
            "engine": engine.name,
            "description": engine.description,
            "machine": f"{platform.system()} {platform.machine()} {platform.mac_ver()[0] or platform.version()}",
            "load_seconds": round(load, 2),
            "warmup_seconds": round(warm.seconds, 2),
            "python_footprint_gb": round(footprint_gb(), 2),
            **engine.memory(),
            "runs": runs,
        }
    finally:
        if hasattr(engine, "close"):
            engine.close()
    (out_dir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    rtfs = [r["rtf"] for r in runs if r["rtf"]]
    firsts = [r["first_audio_seconds"] for r in runs if r["first_audio_seconds"] is not None]
    print(f"{engine.name}: RTF median {np.median(rtfs):.3f}, first audio median {np.median(firsts):.2f}s")


if __name__ == "__main__":
    main()
