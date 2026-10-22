"""Run one engine configuration over the sentences and write the audio and the timings.

Each configuration runs in its own process so the memory numbers are its own. One warm-up sentence runs first and is not
counted (first-call costs: ONNX Runtime's kernel setup, MLX compilation).

Usage:
  uv run bench.py mlx
  uv run bench.py oc --precision int4 --mode matched [--provider coreml] [--threads 8]
  uv run bench.py pl --sampling published [--threads 4 | --provider cuda]

On Windows (CUDA): uv run --project windows bench.py oc --provider cuda ...  (see windows/pyproject.toml)
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
    if args.engine == "mlx":
        from engines.mlx_engine import Engine

        return Engine()
    if args.engine == "oc":
        from engines.oc_engine import Engine

        return Engine(args.precision, args.mode, args.provider, args.threads, no_spin=not args.spin)
    from engines.pl_engine import Engine

    return Engine(args.sampling, args.threads or 4, cuda=args.provider == "cuda")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("engine", choices=["mlx", "oc", "pl"])
    parser.add_argument("--precision", default="int4", choices=["fp32", "fp16", "int4"])
    parser.add_argument("--mode", default="matched", choices=["published", "matched"])
    parser.add_argument("--provider", default="cpu", choices=["cpu", "coreml", "cuda"])
    parser.add_argument("--sampling", default="published", choices=["published", "qwen"])
    parser.add_argument("--threads", type=int, default=0)
    parser.add_argument("--spin", action="store_true", help="oc: keep ONNX Runtime's spinning thread pools (its default)")
    parser.add_argument("--seeds", type=int, nargs="*", default=[0])
    parser.add_argument("--texts", type=int, nargs="*", help="indices into TEXTS (default: all)")
    args = parser.parse_args()

    if args.provider == "cuda":
        import onnxruntime  # noqa: PLC0415

        onnxruntime.preload_dlls()  # the CUDA and cuDNN DLLs from the nvidia-* wheels (onnxruntime-gpu[cuda,cudnn])
    engine = make_engine(args)
    before = footprint_gb()
    started = time.perf_counter()
    engine.load()
    load = time.perf_counter() - started
    loaded = footprint_gb()
    engine.synthesize(WARMUP_TEXT, 0)
    print(f"{engine.name}: load {load:.1f}s, footprint {before:.2f} → {loaded:.2f} GB", flush=True)

    out_dir = LAB_DIR / "output" / engine.name
    out_dir.mkdir(parents=True, exist_ok=True)
    runs = []
    for index in args.texts if args.texts is not None else range(len(TEXTS)):
        for seed in args.seeds:
            result = engine.synthesize(TEXTS[index], seed)
            seconds = len(result.audio) / SAMPLE_RATE
            wav = out_dir / f"t{index}-s{seed}.wav"
            sf.write(wav, np.clip(result.audio, -1.0, 1.0), SAMPLE_RATE, subtype="PCM_16")
            run = {
                "text": index,
                "seed": seed,
                "wav": str(wav.relative_to(LAB_DIR / "output")),
                "audio_seconds": round(seconds, 3),
                "generate_seconds": round(result.seconds, 3),
                "rtf": round(result.seconds / seconds, 3) if seconds else None,
                "first_audio_seconds": round(result.arrivals[0][0], 3) if result.arrivals else None,
                "stall_seconds": round(playback_stalls(result.arrivals), 3) if result.arrivals else None,
                "frames": result.frames,
                "peak": round(float(np.abs(result.audio).max()), 3) if len(result.audio) else 0.0,
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
        "footprint_gb": {"before_load": round(before, 2), "after_load": round(loaded, 2), "after_runs": round(footprint_gb(), 2)},
        **engine.memory(),
        "runs": runs,
    }
    (out_dir / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    rtfs = [r["rtf"] for r in runs if r["rtf"]]
    firsts = [r["first_audio_seconds"] for r in runs if r["first_audio_seconds"] is not None]
    print(f"{engine.name}: RTF median {np.median(rtfs):.3f}, first audio median {np.median(firsts):.2f}s, footprint {report['footprint_gb']}")


if __name__ == "__main__":
    main()
