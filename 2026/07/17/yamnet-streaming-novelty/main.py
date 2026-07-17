from __future__ import annotations

import csv
import hashlib
import json
import math
import os
import platform
import random
import shutil
import subprocess
import tarfile
import time
import urllib.request
from collections import Counter, defaultdict
from dataclasses import dataclass
from importlib import metadata
from pathlib import Path

os.environ.setdefault("TF_CPP_MIN_LOG_LEVEL", "2")

import numpy as np
import tensorflow as tf


LAB_DIR = Path(__file__).resolve().parent
DATA_DIR = LAB_DIR / "data"
MODEL_DIR = LAB_DIR / "models" / "yamnet"
OUTPUT_DIR = LAB_DIR / "output"

SAMPLE_RATE = 16_000
YAMNET_WINDOW_SAMPLES = 15_600
YAMNET_HOP_SAMPLES = 7_680
YAMNET_WINDOW_SECONDS = YAMNET_WINDOW_SAMPLES / SAMPLE_RATE
YAMNET_HOP_SECONDS = YAMNET_HOP_SAMPLES / SAMPLE_RATE
YAMNET_URL = "https://tfhub.dev/google/yamnet/1?tf-hub-format=compressed"
YAMNET_ARCHIVE_SHA256 = "b80da2a1a56926fb0767205051a200dd7b3beaf3ea1ea126c42a53943996e5e0"

ESC50_COMMIT = "33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6"
ESC50_RAW = f"https://raw.githubusercontent.com/karolpiczak/ESC-50/{ESC50_COMMIT}"
ESC50_METADATA_URL = f"{ESC50_RAW}/meta/esc50.csv"
ESC50_METADATA_SHA256 = "ca660da60191a97de289983a05821c9382d852a38a2ba8428980816b68cf6246"

NORMAL_CATEGORIES = ("rain", "sea_waves", "wind", "clock_tick")
ANOMALY_CATEGORIES = (
    "crying_baby",
    "door_wood_knock",
    "glass_breaking",
    "siren",
    "car_horn",
    "fireworks",
)
PROFILE_FOLDS = (1, 2, 3)
CALIBRATION_FOLD = 4
EVALUATION_FOLD = 5
SNR_LEVELS_DB = (-10.0, -5.0, 0.0, 5.0)
RANDOM_SEED = 20_260_717
EVENT_ONSET_SECONDS = 2.0
EVENT_DURATION_SECONDS = 1.0
K_NEIGHBORS = 5
MODEL_THRESHOLD_PERCENTILE = 99.0
FLUX_THRESHOLD_PERCENTILE = 99.5
STREAM_MAX_THRESHOLD_PERCENTILE = 100.0

FLUX_WINDOW = 512
FLUX_HOP = 256


@dataclass(frozen=True)
class Clip:
    filename: str
    fold: int
    category: str


@dataclass
class Features:
    embedding: np.ndarray
    scores: np.ndarray
    model_times: np.ndarray
    flux: np.ndarray
    flux_times: np.ndarray
    elapsed_seconds: float


@dataclass(frozen=True)
class PositiveTrial:
    category: str
    snr_db: float
    audio: np.ndarray
    onset: float
    offset: float


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: Path, expected_sha256: str | None = None) -> None:
    if destination.exists():
        if expected_sha256 is not None and sha256_file(destination) != expected_sha256:
            raise RuntimeError(f"SHA-256 mismatch: {destination}")
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    print(f"download: {url}", flush=True)
    request = urllib.request.Request(url, headers={"User-Agent": "kiarina-labs"})
    with urllib.request.urlopen(request) as response, temporary.open("wb") as file:
        shutil.copyfileobj(response, file)
    if expected_sha256 is not None and sha256_file(temporary) != expected_sha256:
        temporary.unlink()
        raise RuntimeError(f"SHA-256 mismatch: {url}")
    temporary.replace(destination)


def prepare_model() -> Path:
    saved_model = MODEL_DIR / "saved_model.pb"
    if saved_model.exists():
        return MODEL_DIR
    archive = LAB_DIR / "models" / "yamnet.tar.gz"
    download(YAMNET_URL, archive, YAMNET_ARCHIVE_SHA256)
    MODEL_DIR.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as tar:
        members = tar.getmembers()
        for member in members:
            target = (MODEL_DIR / member.name).resolve()
            if not target.is_relative_to(MODEL_DIR.resolve()):
                raise RuntimeError(f"unsafe archive member: {member.name}")
        tar.extractall(MODEL_DIR, members=members, filter="data")
    if not saved_model.exists():
        raise FileNotFoundError(saved_model)
    return MODEL_DIR


def prepare_clips() -> tuple[list[Clip], Path]:
    metadata_path = DATA_DIR / "esc50.csv"
    download(ESC50_METADATA_URL, metadata_path, ESC50_METADATA_SHA256)
    with metadata_path.open(newline="", encoding="utf-8") as file:
        rows = list(csv.DictReader(file))
    categories = set(NORMAL_CATEGORIES) | set(ANOMALY_CATEGORIES)
    clips = [
        Clip(row["filename"], int(row["fold"]), row["category"])
        for row in rows
        if row["category"] in categories
        and (
            row["category"] in NORMAL_CATEGORIES
            or int(row["fold"]) == EVALUATION_FOLD
        )
    ]
    audio_dir = DATA_DIR / "audio"
    for clip in clips:
        download(f"{ESC50_RAW}/audio/{clip.filename}", audio_dir / clip.filename)
    return clips, audio_dir


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
    return np.frombuffer(result.stdout, dtype="<f4").astype(np.float32)


def frame_starts(length: int, window: int, hop: int) -> list[int]:
    if length < window:
        return []
    return list(range(0, length - window + 1, hop))


class Yamnet:
    def __init__(self, model_path: Path) -> None:
        self.model = tf.saved_model.load(str(model_path))
        class_map = model_path / "assets" / "yamnet_class_map.csv"
        with class_map.open(newline="", encoding="utf-8") as file:
            self.labels = [row["display_name"] for row in csv.DictReader(file)]
        # Warm up graph tracing and kernels outside measured regions.
        self.model(np.zeros(YAMNET_WINDOW_SAMPLES, dtype=np.float32))

    def infer_windows(self, audio: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
        starts = frame_starts(len(audio), YAMNET_WINDOW_SAMPLES, YAMNET_HOP_SAMPLES)
        score_rows: list[np.ndarray] = []
        embedding_rows: list[np.ndarray] = []
        for start in starts:
            scores, embeddings, _ = self.model(audio[start : start + YAMNET_WINDOW_SAMPLES])
            if tuple(scores.shape) != (1, 521) or tuple(embeddings.shape) != (1, 1024):
                raise RuntimeError(
                    f"unexpected YAMNet shapes: scores={scores.shape}, embeddings={embeddings.shape}"
                )
            score_rows.append(scores.numpy()[0])
            embedding_rows.append(embeddings.numpy()[0])
        times = (np.asarray(starts, dtype=np.float64) + YAMNET_WINDOW_SAMPLES) / SAMPLE_RATE
        return (
            np.asarray(score_rows, dtype=np.float32),
            np.asarray(embedding_rows, dtype=np.float32),
            times,
        )


def spectral_flux(audio: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    starts = frame_starts(len(audio), FLUX_WINDOW, FLUX_HOP)
    if not starts:
        return np.empty(0, dtype=np.float32), np.empty(0, dtype=np.float64)
    window = np.hanning(FLUX_WINDOW).astype(np.float32)
    magnitudes = []
    for start in starts:
        magnitude = np.abs(np.fft.rfft(audio[start : start + FLUX_WINDOW] * window))
        magnitude /= max(float(magnitude.sum()), 1e-12)
        magnitudes.append(magnitude)
    spectrum = np.asarray(magnitudes, dtype=np.float32)
    flux = np.zeros(len(spectrum), dtype=np.float32)
    flux[1:] = np.maximum(spectrum[1:] - spectrum[:-1], 0.0).sum(axis=1)
    times = (np.asarray(starts, dtype=np.float64) + FLUX_WINDOW) / SAMPLE_RATE
    return flux, times


def extract_features(model: Yamnet, audio: np.ndarray) -> Features:
    started = time.perf_counter()
    scores, embedding, model_times = model.infer_windows(audio)
    flux, flux_times = spectral_flux(audio)
    return Features(
        embedding=embedding,
        scores=scores,
        model_times=model_times,
        flux=flux,
        flux_times=flux_times,
        elapsed_seconds=time.perf_counter() - started,
    )


def unit_rows(values: np.ndarray) -> np.ndarray:
    norms = np.linalg.norm(values, axis=1, keepdims=True)
    return values / np.maximum(norms, 1e-12)


def cosine_knn(query: np.ndarray, reference: np.ndarray, k: int) -> np.ndarray:
    query = unit_rows(query)
    reference = unit_rows(reference)
    similarities = query @ reference.T
    k = min(k, similarities.shape[1])
    nearest = np.partition(similarities, similarities.shape[1] - k, axis=1)[:, -k:]
    return 1.0 - nearest.mean(axis=1)


def cosine_delta(values: np.ndarray) -> np.ndarray:
    normalized = unit_rows(values)
    delta = np.zeros(len(normalized), dtype=np.float32)
    delta[1:] = 1.0 - np.sum(normalized[1:] * normalized[:-1], axis=1)
    return delta


def peak_segment(audio: np.ndarray, duration_samples: int) -> np.ndarray:
    energy_window = int(0.1 * SAMPLE_RATE)
    squared = np.square(audio.astype(np.float64))
    cumulative = np.concatenate(([0.0], np.cumsum(squared)))
    energies = cumulative[energy_window:] - cumulative[:-energy_window]
    center = int(np.argmax(energies)) + energy_window // 2
    start = min(max(center - duration_samples // 2, 0), len(audio) - duration_samples)
    segment = audio[start : start + duration_samples].copy()
    fade = int(0.005 * SAMPLE_RATE)
    ramp = np.sin(np.linspace(0.0, math.pi / 2.0, fade, endpoint=False)) ** 2
    segment[:fade] *= ramp
    segment[-fade:] *= ramp[::-1]
    return segment


def rms(audio: np.ndarray) -> float:
    return float(np.sqrt(np.mean(np.square(audio.astype(np.float64))) + 1e-12))


def mix_event(background: np.ndarray, event: np.ndarray, snr_db: float) -> np.ndarray:
    onset = round(EVENT_ONSET_SECONDS * SAMPLE_RATE)
    event = peak_segment(event, round(EVENT_DURATION_SECONDS * SAMPLE_RATE))
    background = background.copy()
    background_rms = rms(background[onset : onset + len(event)])
    scale = background_rms * (10.0 ** (snr_db / 20.0)) / max(rms(event), 1e-12)
    background[onset : onset + len(event)] += event * scale
    peak = float(np.max(np.abs(background)))
    if peak > 0.99:
        background *= 0.99 / peak
    return background.astype(np.float32)


def build_trials(
    clips: list[Clip], decoded: dict[str, np.ndarray]
) -> tuple[list[np.ndarray], list[PositiveTrial]]:
    backgrounds = sorted(
        (
            clip
            for clip in clips
            if clip.category in NORMAL_CATEGORIES and clip.fold == EVALUATION_FOLD
        ),
        key=lambda clip: clip.filename,
    )
    anomalies_by_class: dict[str, list[Clip]] = defaultdict(list)
    for clip in clips:
        if clip.category in ANOMALY_CATEGORIES and clip.fold == EVALUATION_FOLD:
            anomalies_by_class[clip.category].append(clip)
    rng = random.Random(RANDOM_SEED)
    shuffled_backgrounds = backgrounds.copy()
    rng.shuffle(shuffled_backgrounds)
    positives: list[PositiveTrial] = []
    background_index = 0
    for category in ANOMALY_CATEGORIES:
        anomaly_clips = sorted(anomalies_by_class[category], key=lambda clip: clip.filename)
        if len(anomaly_clips) != 8:
            raise RuntimeError(f"expected 8 fold-5 clips for {category}, got {len(anomaly_clips)}")
        for index, anomaly in enumerate(anomaly_clips):
            background = shuffled_backgrounds[background_index % len(shuffled_backgrounds)]
            background_index += 1
            snr_db = SNR_LEVELS_DB[index % len(SNR_LEVELS_DB)]
            positives.append(
                PositiveTrial(
                    category=category,
                    snr_db=snr_db,
                    audio=mix_event(decoded[background.filename], decoded[anomaly.filename], snr_db),
                    onset=EVENT_ONSET_SECONDS,
                    offset=EVENT_ONSET_SECONDS + EVENT_DURATION_SECONDS,
                )
            )
    negatives = [decoded[clip.filename] for clip in backgrounds]
    return negatives, positives


def active_episodes(times: np.ndarray, active: np.ndarray, merge_gap: float) -> list[list[float]]:
    selected = [float(time_) for time_, is_active in zip(times, active, strict=True) if is_active]
    if not selected:
        return []
    episodes = [[selected[0]]]
    for timestamp in selected[1:]:
        if timestamp - episodes[-1][-1] <= merge_gap + 1e-9:
            episodes[-1].append(timestamp)
        else:
            episodes.append([timestamp])
    return episodes


def fuse_episodes(*groups: list[list[float]]) -> list[list[float]]:
    timestamps = sorted(timestamp for group in groups for episode in group for timestamp in episode)
    if not timestamps:
        return []
    episodes = [[timestamps[0]]]
    for timestamp in timestamps[1:]:
        if timestamp - episodes[-1][-1] <= 0.5 + 1e-9:
            episodes[-1].append(timestamp)
        else:
            episodes.append([timestamp])
    return episodes


def summarize_method(
    name: str,
    positive_episodes: list[list[list[float]]],
    negative_episodes: list[list[list[float]]],
    trials: list[PositiveTrial],
) -> dict:
    detected = 0
    true_alerts = 0
    negative_false_alerts = sum(len(episodes) for episodes in negative_episodes)
    false_alerts = negative_false_alerts
    latencies: list[float] = []
    per_snr: dict[float, dict[str, list[float] | int]] = {
        snr: {"count": 0, "detected": 0, "latencies": []} for snr in SNR_LEVELS_DB
    }
    per_class: dict[str, dict[str, list[float] | int]] = {
        category: {"count": 0, "detected": 0, "latencies": []}
        for category in ANOMALY_CATEGORIES
    }
    for episodes, trial in zip(positive_episodes, trials, strict=True):
        accepted: list[list[float]] = []
        rejected = 0
        tail = YAMNET_WINDOW_SECONDS if name != "spectral_flux" else FLUX_WINDOW / SAMPLE_RATE
        for episode in episodes:
            matching = [
                timestamp
                for timestamp in episode
                if trial.onset <= timestamp <= trial.offset + tail
            ]
            if matching:
                accepted.append(matching)
            else:
                rejected += 1
        false_alerts += rejected + max(0, len(accepted) - 1)
        per_snr[trial.snr_db]["count"] += 1  # type: ignore[operator]
        per_class[trial.category]["count"] += 1  # type: ignore[operator]
        if accepted:
            detected += 1
            true_alerts += 1
            latency = min(min(episode) for episode in accepted) - trial.onset
            latencies.append(latency)
            per_snr[trial.snr_db]["detected"] += 1  # type: ignore[operator]
            per_snr[trial.snr_db]["latencies"].append(latency)  # type: ignore[union-attr]
            per_class[trial.category]["detected"] += 1  # type: ignore[operator]
            per_class[trial.category]["latencies"].append(latency)  # type: ignore[union-attr]

    precision = true_alerts / max(true_alerts + false_alerts, 1)
    recall = detected / len(trials)
    f1 = 2 * precision * recall / max(precision + recall, 1e-12)
    negative_hours = len(negative_episodes) * 5.0 / 3600.0

    def finalize(groups: dict) -> dict:
        result = {}
        for key, values in groups.items():
            values = dict(values)
            group_latencies = values.pop("latencies")
            values["recall"] = values["detected"] / values["count"]
            values["latency_median_seconds"] = (
                float(np.median(group_latencies)) if group_latencies else None
            )
            result[str(key)] = values
        return result

    return {
        "positive_trials": len(trials),
        "detected": detected,
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "false_alerts": false_alerts,
        "negative_false_alerts": negative_false_alerts,
        "false_alerts_per_negative_hour": negative_false_alerts / negative_hours,
        "latency_median_seconds": float(np.median(latencies)) if latencies else None,
        "latency_p95_seconds": float(np.percentile(latencies, 95)) if latencies else None,
        "by_snr_db": finalize(per_snr),
        "by_class": finalize(per_class),
    }


def binary_auc(positive: list[float], negative: list[float]) -> float:
    wins = 0.0
    for positive_score in positive:
        for negative_score in negative:
            if positive_score > negative_score:
                wins += 1.0
            elif positive_score == negative_score:
                wins += 0.5
    return wins / (len(positive) * len(negative))


def main() -> None:
    random.seed(RANDOM_SEED)
    np.random.seed(RANDOM_SEED)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    model_path = prepare_model()
    clips, audio_dir = prepare_clips()

    print("decode selected ESC-50 clips", flush=True)
    decoded = {clip.filename: decode_audio(audio_dir / clip.filename) for clip in clips}
    model = Yamnet(model_path)

    profile_clips = [
        clip
        for clip in clips
        if clip.category in NORMAL_CATEGORIES and clip.fold in PROFILE_FOLDS
    ]
    calibration_clips = [
        clip
        for clip in clips
        if clip.category in NORMAL_CATEGORIES and clip.fold == CALIBRATION_FOLD
    ]
    negatives, positives = build_trials(clips, decoded)

    print(f"extract profile features: {len(profile_clips)} clips", flush=True)
    profile_features = [extract_features(model, decoded[clip.filename]) for clip in profile_clips]
    reference_embeddings = np.concatenate([item.embedding for item in profile_features])
    reference_scores = np.concatenate([item.scores for item in profile_features])

    print(f"extract calibration features: {len(calibration_clips)} clips", flush=True)
    calibration_features = [
        extract_features(model, decoded[clip.filename]) for clip in calibration_clips
    ]
    def anomaly_values(item: Features, method: str) -> tuple[np.ndarray, np.ndarray]:
        if method == "embedding_knn":
            return (
                cosine_knn(item.embedding, reference_embeddings, K_NEIGHBORS),
                item.model_times,
            )
        if method == "score_knn":
            return (
                cosine_knn(item.scores, reference_scores, K_NEIGHBORS),
                item.model_times,
            )
        if method == "embedding_delta":
            return cosine_delta(item.embedding), item.model_times
        if method == "score_delta":
            return cosine_delta(item.scores), item.model_times
        return item.flux, item.flux_times

    methods = (
        "spectral_flux",
        "score_delta",
        "embedding_delta",
        "score_knn",
        "embedding_knn",
    )
    calibration_values = {
        method: [anomaly_values(item, method)[0] for item in calibration_features]
        for method in methods
    }
    exploratory_thresholds = {}
    for method in methods:
        values = calibration_values[method]
        if method in ("spectral_flux", "score_delta", "embedding_delta"):
            values = [value[1:] for value in values]
        exploratory_thresholds[method] = float(
            np.percentile(
                np.concatenate(values),
                FLUX_THRESHOLD_PERCENTILE
                if method == "spectral_flux"
                else MODEL_THRESHOLD_PERCENTILE,
            )
        )
    thresholds = {
        method: float(
            np.percentile(
                [float(np.max(values)) for values in calibration_values[method]],
                STREAM_MAX_THRESHOLD_PERCENTILE,
            )
        )
        for method in methods
    }

    print(f"extract negative evaluation features: {len(negatives)} streams", flush=True)
    negative_features = [extract_features(model, audio) for audio in negatives]
    print(f"extract positive evaluation features: {len(positives)} streams", flush=True)
    positive_features = [extract_features(model, trial.audio) for trial in positives]

    def method_episodes(
        features: list[Features], method: str, selected_thresholds: dict[str, float]
    ) -> list[list[list[float]]]:
        result = []
        for item in features:
            anomaly, times = anomaly_values(item, method)
            result.append(
                active_episodes(
                    times,
                    anomaly > selected_thresholds[method],
                    YAMNET_HOP_SECONDS
                    if method != "spectral_flux"
                    else FLUX_HOP / SAMPLE_RATE,
                )
            )
        return result

    def build_episode_sets(selected_thresholds: dict[str, float]) -> dict:
        result = {
            method: {
                "positive": method_episodes(positive_features, method, selected_thresholds),
                "negative": method_episodes(negative_features, method, selected_thresholds),
            }
            for method in methods
        }
        result["spectral_embedding_fusion"] = {
            "positive": [
                fuse_episodes(flux, embedding)
                for flux, embedding in zip(
                    result["spectral_flux"]["positive"],
                    result["embedding_knn"]["positive"],
                    strict=True,
                )
            ],
            "negative": [
                fuse_episodes(flux, embedding)
                for flux, embedding in zip(
                    result["spectral_flux"]["negative"],
                    result["embedding_knn"]["negative"],
                    strict=True,
                )
            ],
        }
        result["temporal_fusion"] = {
            "positive": [
                fuse_episodes(score, embedding)
                for score, embedding in zip(
                    result["score_delta"]["positive"],
                    result["embedding_delta"]["positive"],
                    strict=True,
                )
            ],
            "negative": [
                fuse_episodes(score, embedding)
                for score, embedding in zip(
                    result["score_delta"]["negative"],
                    result["embedding_delta"]["negative"],
                    strict=True,
                )
            ],
        }
        return result

    def summarize_episode_sets(episode_sets: dict) -> dict:
        return {
            method: summarize_method(
                method,
                episodes["positive"],
                episodes["negative"],
                positives,
            )
            for method, episodes in episode_sets.items()
        }

    metrics = summarize_episode_sets(build_episode_sets(thresholds))
    exploratory_metrics = summarize_episode_sets(build_episode_sets(exploratory_thresholds))

    ranking_metrics = {}
    for method in methods:
        negative_maxima = [
            float(np.max(anomaly_values(item, method)[0])) for item in negative_features
        ]
        positive_maxima = []
        positive_by_snr: dict[float, list[float]] = defaultdict(list)
        for item, trial in zip(positive_features, positives, strict=True):
            values, times = anomaly_values(item, method)
            tail = (
                YAMNET_WINDOW_SECONDS
                if method != "spectral_flux"
                else FLUX_WINDOW / SAMPLE_RATE
            )
            mask = (times >= trial.onset) & (times <= trial.offset + tail)
            maximum = float(np.max(values[mask]))
            positive_maxima.append(maximum)
            positive_by_snr[trial.snr_db].append(maximum)
        ranking_metrics[method] = {
            "auc": binary_auc(positive_maxima, negative_maxima),
            "positive_median": float(np.median(positive_maxima)),
            "negative_median": float(np.median(negative_maxima)),
            "auc_by_snr_db": {
                str(snr): binary_auc(values, negative_maxima)
                for snr, values in positive_by_snr.items()
            },
        }

    label_summary: dict[str, list[dict[str, int | str]]] = {}
    for category in ANOMALY_CATEGORIES:
        counter: Counter[str] = Counter()
        for trial, features in zip(positives, positive_features, strict=True):
            if trial.category != category:
                continue
            overlapping = [
                index
                for index, timestamp in enumerate(features.model_times)
                if trial.onset <= timestamp <= trial.offset + YAMNET_WINDOW_SECONDS
            ]
            if overlapping:
                mean_scores = features.scores[overlapping].mean(axis=0)
                counter[model.labels[int(np.argmax(mean_scores))]] += 1
        label_summary[category] = [
            {"label": label, "count": count} for label, count in counter.most_common(5)
        ]

    all_features = profile_features + calibration_features + negative_features + positive_features
    total_audio_seconds = 5.0 * len(all_features)
    total_elapsed = sum(item.elapsed_seconds for item in all_features)
    report = {
        "configuration": {
            "random_seed": RANDOM_SEED,
            "dataset": "ESC-50",
            "dataset_revision": ESC50_COMMIT,
            "normal_categories": NORMAL_CATEGORIES,
            "anomaly_categories": ANOMALY_CATEGORIES,
            "profile_folds": PROFILE_FOLDS,
            "calibration_fold": CALIBRATION_FOLD,
            "evaluation_fold": EVALUATION_FOLD,
            "snr_levels_db": SNR_LEVELS_DB,
            "event_onset_seconds": EVENT_ONSET_SECONDS,
            "event_duration_seconds": EVENT_DURATION_SECONDS,
            "profile_clips": len(profile_clips),
            "calibration_clips": len(calibration_clips),
            "negative_streams": len(negatives),
            "positive_streams": len(positives),
            "yamnet_window_seconds": YAMNET_WINDOW_SECONDS,
            "yamnet_hop_seconds": YAMNET_HOP_SECONDS,
            "yamnet_archive_sha256": YAMNET_ARCHIVE_SHA256,
            "knn_neighbors": K_NEIGHBORS,
            "model_threshold_percentile": MODEL_THRESHOLD_PERCENTILE,
            "flux_threshold_percentile": FLUX_THRESHOLD_PERCENTILE,
            "stream_max_threshold_percentile": STREAM_MAX_THRESHOLD_PERCENTILE,
        },
        "thresholds": {
            "primary_calibration_stream_max": thresholds,
            "exploratory_frame_percentile": exploratory_thresholds,
        },
        "metrics": metrics,
        "ranking_metrics": ranking_metrics,
        "exploratory_frame_percentile_metrics": exploratory_metrics,
        "yamnet_top_labels_during_events": label_summary,
        "performance": {
            "processed_audio_seconds": total_audio_seconds,
            "feature_extraction_elapsed_seconds": total_elapsed,
            "real_time_factor": total_elapsed / total_audio_seconds,
        },
        "environment": {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "tensorflow": tf.__version__,
            "numpy": np.__version__,
            "ffmpeg": subprocess.run(
                ["ffmpeg", "-version"], check=True, text=True, capture_output=True
            ).stdout.splitlines()[0],
            "tensorflow_distribution": metadata.version("tensorflow"),
        },
    }
    report_path = OUTPUT_DIR / "report.json"
    report_path.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        json.dumps(
            {
                "thresholds": report["thresholds"],
                "metrics": metrics,
                "ranking_metrics": ranking_metrics,
                "performance": report["performance"],
            },
            indent=2,
        )
    )
    print(f"report: {report_path}")


if __name__ == "__main__":
    main()
