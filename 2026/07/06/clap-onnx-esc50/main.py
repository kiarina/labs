from __future__ import annotations

import argparse
import csv
import hashlib
import json
import subprocess
import time
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import onnxruntime as ort


SAMPLE_RATE = 48_000
MAX_SAMPLES = 480_000
FFT_SIZE = 1024
HOP_LENGTH = 480
MEL_BINS = 64
FREQUENCY_MIN = 50.0
FREQUENCY_MAX = 14_000.0
EMBEDDING_DIMENSION = 512
MODEL_SHA256 = "b23099962830b1afa5398efbb6f5321ef8f63f8fcf93f5019837c47118a8a1c5"
ESC50_COMMIT = "33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6"
ESC50_RAW = f"https://raw.githubusercontent.com/karolpiczak/ESC-50/{ESC50_COMMIT}"
COARSE_CATEGORIES = (
    "animals",
    "natural_soundscapes_and_water",
    "human_non_speech",
    "interior_and_domestic",
    "exterior_and_urban",
)


@dataclass(frozen=True)
class Clip:
    filename: str
    fold: int
    target: int
    category: str

    @property
    def coarse_category(self) -> str:
        return COARSE_CATEGORIES[self.target // 10]


class ClapOnnx:
    def __init__(self, model_path: Path) -> None:
        actual = sha256_file(model_path)
        if actual != MODEL_SHA256:
            raise ValueError(
                f"model SHA-256 mismatch: expected {MODEL_SHA256}, got {actual}"
            )
        self.session = ort.InferenceSession(
            str(model_path), providers=["CPUExecutionProvider"]
        )
        self.mel_filters = mel_filter_bank()

    def embed(self, samples: np.ndarray) -> np.ndarray:
        features = log_mel_spectrogram(fit_waveform(samples), self.mel_filters)
        features = fit_frames(features, MAX_SAMPLES // HOP_LENGTH + 1)
        inputs = {
            "input_features": features.reshape(1, 1, 1001, MEL_BINS),
            "is_longer": np.array([[False]], dtype=bool),
        }
        embedding = np.asarray(
            self.session.run(None, inputs)[0], dtype=np.float32
        ).reshape(-1)
        if embedding.shape != (EMBEDDING_DIMENSION,):
            raise ValueError(f"unexpected embedding shape: {embedding.shape}")
        norm = float(np.linalg.norm(embedding))
        if not np.isfinite(norm) or norm == 0:
            raise ValueError(f"invalid embedding norm: {norm}")
        return embedding / norm


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: Path) -> None:
    if destination.exists():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    print(f"download: {url}", flush=True)
    urllib.request.urlretrieve(url, temporary)
    temporary.replace(destination)


def load_clips(data_dir: Path) -> list[Clip]:
    metadata = data_dir / "esc50.csv"
    download(f"{ESC50_RAW}/meta/esc50.csv", metadata)
    with metadata.open(newline="", encoding="utf-8") as file:
        rows = list(csv.DictReader(file))

    selected = []
    for fold in (1, 5):
        by_target: dict[int, dict[str, str]] = {}
        for row in rows:
            if int(row["fold"]) == fold:
                by_target.setdefault(int(row["target"]), row)
        if set(by_target) != set(range(50)):
            raise ValueError(f"fold {fold} does not contain all 50 targets")
        for target in range(50):
            row = by_target[target]
            selected.append(
                Clip(
                    filename=row["filename"],
                    fold=fold,
                    target=target,
                    category=row["category"],
                )
            )

    for clip in selected:
        download(f"{ESC50_RAW}/audio/{clip.filename}", data_dir / clip.filename)
    return selected


def decode_audio(path: Path) -> np.ndarray:
    result = subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-i",
            str(path),
            "-ac",
            "1",
            "-ar",
            str(SAMPLE_RATE),
            "-f",
            "f32le",
            "-",
        ],
        check=True,
        stdout=subprocess.PIPE,
    )
    return np.frombuffer(result.stdout, dtype="<f4")


def fit_waveform(samples: np.ndarray) -> np.ndarray:
    if len(samples) >= MAX_SAMPLES:
        start = (len(samples) - MAX_SAMPLES) // 2
        return samples[start : start + MAX_SAMPLES].astype(np.float32)
    if len(samples) == 0:
        return np.zeros(MAX_SAMPLES, dtype=np.float32)
    repeats = MAX_SAMPLES // len(samples)
    repeated = np.tile(samples, repeats)
    return np.pad(repeated, (0, MAX_SAMPLES - len(repeated))).astype(np.float32)


def log_mel_spectrogram(
    samples: np.ndarray, mel_filters: np.ndarray
) -> np.ndarray:
    pad = FFT_SIZE // 2
    samples = np.pad(samples, (pad, pad), mode="reflect")
    window = np.hanning(FFT_SIZE + 1)[:-1].astype(np.float32)
    frames = np.lib.stride_tricks.sliding_window_view(samples, FFT_SIZE)[
        ::HOP_LENGTH
    ]
    spectrum = np.fft.rfft(frames * window, n=FFT_SIZE)
    mel = np.maximum((np.abs(spectrum) ** 2) @ mel_filters, 1e-10)
    return (10.0 * np.log10(mel)).astype(np.float32)


def fit_frames(mel: np.ndarray, expected: int) -> np.ndarray:
    if len(mel) >= expected:
        return mel[:expected].astype(np.float32)
    return np.pad(mel, ((0, expected - len(mel)), (0, 0))).astype(np.float32)


def mel_filter_bank() -> np.ndarray:
    def hz_to_mel(value: float | np.ndarray) -> np.ndarray:
        return np.asarray(2595.0 * np.log10(1.0 + np.asarray(value) / 700.0))

    def mel_to_hz(value: np.ndarray) -> np.ndarray:
        return 700.0 * (10.0 ** (value / 2595.0) - 1.0)

    points = mel_to_hz(
        np.linspace(hz_to_mel(FREQUENCY_MIN), hz_to_mel(FREQUENCY_MAX), MEL_BINS + 2)
    )
    frequencies = np.linspace(0.0, SAMPLE_RATE / 2, FFT_SIZE // 2 + 1)
    filters = np.zeros((len(frequencies), MEL_BINS), dtype=np.float32)
    for index in range(MEL_BINS):
        lower, center, upper = points[index : index + 3]
        rising = (frequencies - lower) / (center - lower)
        falling = (upper - frequencies) / (upper - center)
        filters[:, index] = np.maximum(0.0, np.minimum(rising, falling))
    return filters


def evaluate(clips: list[Clip], embeddings: np.ndarray, elapsed: float) -> dict:
    references = [(clip, vector) for clip, vector in zip(clips, embeddings) if clip.fold == 1]
    queries = [(clip, vector) for clip, vector in zip(clips, embeddings) if clip.fold == 5]
    reference_matrix = np.stack([vector for _, vector in references])
    results = []
    for query, vector in queries:
        similarities = reference_matrix @ vector
        order = np.argsort(similarities)[::-1]
        nearest = references[int(order[0])][0]
        top5 = [references[int(index)][0] for index in order[:5]]
        results.append(
            {
                "query": query.filename,
                "actual_category": query.category,
                "actual_coarse_category": query.coarse_category,
                "nearest": nearest.filename,
                "predicted_category": nearest.category,
                "predicted_coarse_category": nearest.coarse_category,
                "similarity": float(similarities[order[0]]),
                "fine_correct": nearest.target == query.target,
                "coarse_correct": nearest.coarse_category == query.coarse_category,
                "fine_top5_correct": any(item.target == query.target for item in top5),
            }
        )
    count = len(results)
    return {
        "configuration": {
            "dataset": "ESC-50",
            "dataset_revision": ESC50_COMMIT,
            "reference_fold": 1,
            "query_fold": 5,
            "clips_per_fold": 50,
            "embedding_dimension": EMBEDDING_DIMENSION,
            "sample_rate": SAMPLE_RATE,
            "model_sha256": MODEL_SHA256,
        },
        "metrics": {
            "fine_accuracy_at_1": sum(item["fine_correct"] for item in results) / count,
            "fine_accuracy_at_5": sum(item["fine_top5_correct"] for item in results) / count,
            "coarse_accuracy_at_1": sum(item["coarse_correct"] for item in results) / count,
            "embedding_elapsed_seconds": elapsed,
            "seconds_per_clip": elapsed / len(clips),
        },
        "results": results,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, default=Path("model.onnx"))
    parser.add_argument("--data-dir", type=Path, default=Path("data"))
    parser.add_argument("--output", type=Path, default=Path("output/report.json"))
    args = parser.parse_args()

    clips = load_clips(args.data_dir)
    model = ClapOnnx(args.model)
    embeddings = []
    started = time.perf_counter()
    for index, clip in enumerate(clips, 1):
        print(f"embed {index:3d}/{len(clips)}: {clip.filename}", flush=True)
        embeddings.append(model.embed(decode_audio(args.data_dir / clip.filename)))
    elapsed = time.perf_counter() - started
    report = evaluate(clips, np.stack(embeddings), elapsed)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    metrics = report["metrics"]
    print(json.dumps(metrics, indent=2))
    print(f"report: {args.output}")


if __name__ == "__main__":
    main()
