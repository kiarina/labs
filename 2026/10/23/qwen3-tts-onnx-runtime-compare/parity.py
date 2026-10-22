"""Check the onnx-community codec and speaker encoder against mlx-audio on the same reference (MLX as the yardstick).

1. Reference codes: MLX encodes the whole reference at once; `published` encodes independent 1 s windows padded to 1 s;
   `matched` gives each window 6 frames of real left context and trims to the audio's length.
2. x-vector: cosine similarity of the speaker embeddings.
3. Decoding the same codes: MLX's whole-sequence decode against `published` (independent 25-frame chunks) and `matched`
   (12 frames of left context, 13 new frames per call). Also whether the 25-frame decoder is causal (padding after a frame
   must not change it).

Usage: uv run parity.py
"""

from __future__ import annotations

import json

import mlx.core as mx
import numpy as np
import soundfile as sf
from huggingface_hub import snapshot_download
from mlx_audio.tts.utils import load_model

from engines.common import LAB_DIR, reference_wav
from engines.mlx_engine import REPO, REVISION
from engines.oc_engine import SAMPLES_PER_FRAME, Engine


def snr_db(reference: np.ndarray, test: np.ndarray) -> float:
    n = min(len(reference), len(test))
    noise = reference[:n] - test[:n]
    return float(10 * np.log10(np.sum(reference[:n] ** 2) / max(np.sum(noise**2), 1e-20)))


def lsd_db(reference: np.ndarray, test: np.ndarray, n_fft: int = 1024, hop: int = 256) -> float:
    """Log-spectral distance (dB): insensitive to small phase differences, which waveform SNR is not."""
    n = min(len(reference), len(test))
    window = np.hanning(n_fft)

    def spec(x):
        frames = np.lib.stride_tricks.sliding_window_view(x[:n], n_fft)[::hop] * window
        return np.log10(np.abs(np.fft.rfft(frames, axis=-1)) ** 2 + 1e-10)

    return float(np.mean(np.sqrt(np.mean((10 * (spec(reference) - spec(test))) ** 2, axis=-1))))


def main() -> None:
    wav, _ = sf.read(reference_wav(), dtype="float32")
    model = load_model(snapshot_download(REPO, revision=REVISION))
    mlx_codes = np.array(model.speech_tokenizer.encode(mx.array(wav)[None, None]))[0].T.astype(np.int64)  # [T, 16]
    mlx_xvec = np.array(model.extract_speaker_embedding(mx.array(wav))).reshape(-1)
    mlx_wav = np.array(model.speech_tokenizer.decode(mx.array(mlx_codes)[None])[0]).reshape(-1)  # (wav, lengths)

    report = {"reference_seconds": round(len(wav) / 24000, 3), "mlx_frames": len(mlx_codes)}
    engines = {mode: Engine("fp32", mode) for mode in ("published", "matched")}
    for mode, engine in engines.items():
        engine.load()
        codes = engine.ref_codes
        n = min(len(codes), len(mlx_codes))
        report[f"encode_{mode}"] = {
            "frames": len(codes),
            "first_codebook_match": round(float(np.mean(codes[:n, 0] == mlx_codes[:n, 0])), 3),
            "all_codebooks_match": round(float(np.mean(codes[:n] == mlx_codes[:n])), 3),
        }
    onnx_xvec = engines["matched"].xvector.reshape(-1)
    report["xvector_cosine"] = round(float(onnx_xvec @ mlx_xvec / np.linalg.norm(onnx_xvec) / np.linalg.norm(mlx_xvec)), 6)

    # Decode MLX's own reference codes both ways, 13 / 25 frames at a time as the engine does while streaming.
    out = LAB_DIR / "output/parity"
    out.mkdir(parents=True, exist_ok=True)
    sf.write(out / "mlx-decode.wav", mlx_wav, 24000, subtype="PCM_16")
    for mode, engine in engines.items():
        per = 25 - engine.decoder_context
        pieces = [engine._decode(mlx_codes, s, min(s + per, len(mlx_codes))) for s in range(0, len(mlx_codes), per)]
        onnx_wav = np.concatenate(pieces)
        sf.write(out / f"onnx-decode-{mode}.wav", onnx_wav, 24000, subtype="PCM_16")
        diff = mlx_wav[: len(onnx_wav)] - onnx_wav[: len(mlx_wav)]
        boundaries = [s * SAMPLES_PER_FRAME for s in range(per, len(mlx_codes), per)]
        near = np.concatenate([diff[max(b - 480, 0) : b + 480] for b in boundaries]) if boundaries else diff[:0]
        report[f"decode_{mode}"] = {
            "snr_db_vs_mlx": round(snr_db(mlx_wav, onnx_wav), 2),
            "lsd_db_vs_mlx": round(lsd_db(mlx_wav, onnx_wav), 2),
            "rms_error_near_boundaries": round(float(np.sqrt(np.mean(near**2))), 5) if len(near) else None,
            "rms_error_elsewhere": round(float(np.sqrt(np.mean(diff**2))), 5),
        }

    engine = engines["matched"]
    full = engine.decoder.run({"audio_codes": mlx_codes[None, :25]})[0].reshape(-1)
    padded = mlx_codes[np.r_[np.arange(13), np.zeros(12, int)]]  # same first 13 frames, then different frames
    part = engine.decoder.run({"audio_codes": padded[None]})[0].reshape(-1)
    k = 13 * SAMPLES_PER_FRAME
    report["decoder_causal_max_abs_diff_first_13_frames"] = float(np.max(np.abs(full[:k] - part[:k])))
    print(json.dumps(report, indent=2))
    (out / "parity.json").write_text(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
