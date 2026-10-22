"""Switch the reference voice of one pltobing engine between requests (what kiapi's registered voices need).

The port takes the reference at construction (`audio_ref_path`) and computes the x-vector from it at every prefill. To use
another voice, this sets the path, clears the history of reference chunks it keeps for its continuous multi-turn mode, and
resets the turn. It speaks the same sentence as speaker 1, speaker 2, then speaker 1 again (the voice must not leak).

Usage (Windows): uv run --project windows voice_switch.py --provider cuda
"""

from __future__ import annotations

import argparse
import json
import time

import numpy as np
import soundfile as sf

from engines.common import LAB_DIR, SAMPLE_RATE, TEXTS, WARMUP_TEXT, reference_wav


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--provider", default="cpu", choices=["cpu", "cuda"])
    args = parser.parse_args()
    if args.provider == "cuda":
        import onnxruntime  # noqa: PLC0415

        onnxruntime.preload_dlls()
    from engines.pl_engine import Engine  # noqa: PLC0415

    engine = Engine(cuda=args.provider == "cuda")
    engine.load()
    engine.synthesize(WARMUP_TEXT, 0)
    inner = engine.engine
    out = LAB_DIR / "output/voice-switch"
    out.mkdir(parents=True, exist_ok=True)
    runs = []
    for order, speaker in enumerate([1, 2, 1]):
        started = time.perf_counter()
        inner._audio_ref_path = str(reference_wav(speaker))
        inner._ref_wav_history_list = None  # chunks of the old reference, kept for its continuous multi-turn mode
        xvector = np.asarray(inner.create_voice_clone_spkemb(inner._audio_ref_path)).reshape(-1)
        switch = time.perf_counter() - started
        result = engine.synthesize(TEXTS[0], 0)
        wav = out / f"{order}-speaker{speaker}.wav"
        sf.write(wav, np.clip(result.audio, -1, 1), SAMPLE_RATE, subtype="PCM_16")
        runs.append(
            {
                "speaker": speaker,
                "wav": wav.name,
                "xvector_seconds": round(switch, 3),
                "audio_seconds": round(len(result.audio) / SAMPLE_RATE, 2),
                "first_audio_seconds": round(result.arrivals[0][0], 3),
                "rtf": round(result.seconds / (len(result.audio) / SAMPLE_RATE), 3),
                "xvector": xvector,
            }
        )
        print({k: v for k, v in runs[-1].items() if k != "xvector"}, flush=True)
    a, b = runs[0]["xvector"], runs[1]["xvector"]
    report = {
        "xvector_cosine_speaker1_vs_speaker2": round(float(a @ b / np.linalg.norm(a) / np.linalg.norm(b)), 4),
        "runs": [{k: v for k, v in r.items() if k != "xvector"} for r in runs],
    }
    print(json.dumps(report, indent=2))
    (out / "report.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
