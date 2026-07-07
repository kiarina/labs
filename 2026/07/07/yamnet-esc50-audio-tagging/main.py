from __future__ import annotations

import argparse
import csv
import hashlib
import json
import platform
import shutil
import subprocess
import sys
import time
import urllib.request
import zipfile
from dataclasses import dataclass
from importlib import metadata
from pathlib import Path

import numpy as np
from ai_edge_litert.interpreter import Interpreter  # type: ignore


SAMPLE_RATE = 16_000
MODEL_URL = (
    "https://tfhub.dev/google/lite-model/yamnet/classification/tflite/1"
    "?lite-format=tflite"
)
MODEL_SHA256 = "10c95ea3eb9a7bb4cb8bddf6feb023250381008177ac162ce169694d05c317de"
CLASS_MAP_COMMIT = "5c597f85268743140854f0e670f2175e8668553a"
CLASS_MAP_URL = (
    "https://raw.githubusercontent.com/tensorflow/models/"
    f"{CLASS_MAP_COMMIT}/research/audioset/yamnet/yamnet_class_map.csv"
)
CLASS_MAP_SHA256 = "cdf24d193e196d9e95912a2667051ae203e92a2ba09449218ccb40ef787c6df2"
ESC50_COMMIT = "33c8ce9eb2cf0b1c2f8bcf322eb349b6be34dbb6"
ESC50_ARCHIVE_URL = f"https://github.com/karolpiczak/ESC-50/archive/{ESC50_COMMIT}.zip"
ESC50_ROOT = f"ESC-50-{ESC50_COMMIT}"

COARSE_CATEGORIES = (
    "animals",
    "natural_soundscapes_and_water",
    "human_non_speech",
    "interior_and_domestic",
    "exterior_and_urban",
)

ESC50_TO_YAMNET = {
    "dog": ["Dog", "Bark"],
    "rooster": ["Chicken, rooster", "Crowing, cock-a-doodle-doo"],
    "pig": ["Pig", "Oink"],
    "cow": ["Cattle, bovinae", "Moo"],
    "frog": ["Frog", "Croak"],
    "cat": ["Cat", "Meow", "Purr"],
    "hen": ["Chicken, rooster", "Cluck"],
    "insects": ["Insect"],
    "sheep": ["Sheep", "Bleat"],
    "crow": ["Crow", "Caw"],
    "rain": ["Rain", "Raindrop", "Rain on surface"],
    "sea_waves": ["Waves, surf", "Ocean"],
    "crackling_fire": ["Fire", "Crackle"],
    "crickets": ["Cricket"],
    "chirping_birds": ["Bird vocalization, bird call, bird song", "Chirp, tweet"],
    "water_drops": ["Drip", "Water", "Raindrop"],
    "wind": ["Wind"],
    "pouring_water": ["Pour", "Water", "Liquid"],
    "toilet_flush": ["Toilet flush"],
    "thunderstorm": ["Thunderstorm", "Thunder"],
    "crying_baby": ["Baby cry, infant cry", "Crying, sobbing"],
    "sneezing": ["Sneeze"],
    "clapping": ["Clapping"],
    "breathing": ["Breathing"],
    "coughing": ["Cough"],
    "footsteps": ["Walk, footsteps"],
    "laughing": ["Laughter"],
    "brushing_teeth": ["Toothbrush", "Electric toothbrush"],
    "snoring": ["Snoring"],
    "drinking_sipping": ["Liquid", "Gurgling", "Slosh"],
    "door_wood_knock": ["Knock", "Door"],
    "mouse_click": ["Clicking"],
    "keyboard_typing": ["Typing", "Computer keyboard"],
    "door_wood_creaks": ["Creak", "Door"],
    "can_opening": ["Clicking", "Crack"],
    "washing_machine": ["Mechanisms", "Water", "Environmental noise"],
    "vacuum_cleaner": ["Vacuum cleaner"],
    "clock_alarm": ["Alarm clock", "Alarm"],
    "clock_tick": ["Tick", "Tick-tock", "Clock"],
    "glass_breaking": ["Glass", "Shatter", "Breaking"],
    "helicopter": ["Helicopter"],
    "chainsaw": ["Chainsaw"],
    "siren": ["Siren"],
    "car_horn": ["Vehicle horn, car horn, honking"],
    "engine": ["Engine"],
    "train": ["Train", "Rail transport"],
    "church_bells": ["Church bell", "Bell"],
    "airplane": ["Fixed-wing aircraft, airplane", "Aircraft", "Aircraft engine"],
    "fireworks": ["Fireworks", "Firecracker"],
    "hand_saw": ["Sawing"],
}

DIRECT_CATEGORIES = {
    "dog",
    "rooster",
    "pig",
    "cow",
    "frog",
    "cat",
    "sheep",
    "crow",
    "rain",
    "sea_waves",
    "crackling_fire",
    "crickets",
    "chirping_birds",
    "wind",
    "toilet_flush",
    "thunderstorm",
    "crying_baby",
    "sneezing",
    "clapping",
    "breathing",
    "coughing",
    "footsteps",
    "laughing",
    "brushing_teeth",
    "snoring",
    "keyboard_typing",
    "vacuum_cleaner",
    "clock_alarm",
    "clock_tick",
    "glass_breaking",
    "helicopter",
    "chainsaw",
    "siren",
    "car_horn",
    "engine",
    "train",
    "church_bells",
    "airplane",
    "fireworks",
    "hand_saw",
}


@dataclass(frozen=True)
class Clip:
    filename: str
    fold: int
    target: int
    category: str

    @property
    def coarse_category(self) -> str:
        return COARSE_CATEGORIES[self.target // 10]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url: str, destination: Path, expected_sha256: str | None = None) -> None:
    if destination.exists():
        verify_file(destination, expected_sha256)
        return

    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    print(f"download: {url}", flush=True)
    request = urllib.request.Request(url, headers={"User-Agent": "kiarina-labs"})
    with urllib.request.urlopen(request) as response:
        with temporary.open("wb") as file:
            shutil.copyfileobj(response, file)
    verify_file(temporary, expected_sha256)
    temporary.replace(destination)


def verify_file(path: Path, expected_sha256: str | None) -> None:
    if expected_sha256 is None:
        return
    actual = sha256_file(path)
    if actual != expected_sha256:
        raise ValueError(f"SHA-256 mismatch for {path}: expected {expected_sha256}, got {actual}")


def prepare_resources(model_dir: Path, data_dir: Path) -> tuple[Path, Path, Path]:
    model_path = model_dir / "yamnet.tflite"
    class_map_path = model_dir / "yamnet_class_map.csv"
    archive_path = data_dir / f"ESC-50-{ESC50_COMMIT}.zip"
    dataset_path = data_dir / ESC50_ROOT

    download(MODEL_URL, model_path, MODEL_SHA256)
    download(CLASS_MAP_URL, class_map_path, CLASS_MAP_SHA256)
    download(ESC50_ARCHIVE_URL, archive_path)

    metadata_path = dataset_path / "meta" / "esc50.csv"
    if not metadata_path.exists():
        print(f"extract: {archive_path}", flush=True)
        data_dir.mkdir(parents=True, exist_ok=True)
        with zipfile.ZipFile(archive_path) as archive:
            archive.extractall(data_dir)
    if not metadata_path.exists():
        raise FileNotFoundError(f"ESC-50 metadata not found: {metadata_path}")
    return model_path, class_map_path, dataset_path


def load_labels(class_map_path: Path) -> list[str]:
    with class_map_path.open(newline="", encoding="utf-8") as file:
        reader = csv.DictReader(file)
        if reader.fieldnames is None or "display_name" not in reader.fieldnames:
            raise ValueError("class map must contain a display_name column")
        return [row["display_name"] for row in reader]


def label_indices(labels: list[str]) -> dict[str, list[int]]:
    by_label = {label: index for index, label in enumerate(labels)}
    indices: dict[str, list[int]] = {}
    missing: dict[str, list[str]] = {}
    for category, names in ESC50_TO_YAMNET.items():
        found = [by_label[name] for name in names if name in by_label]
        absent = [name for name in names if name not in by_label]
        if absent:
            missing[category] = absent
        indices[category] = found
    if missing:
        raise ValueError(f"YAMNet class map is missing mapped labels: {missing}")
    return indices


def load_clips(
    dataset_path: Path, folds: set[int] | None, limit_per_class: int | None
) -> list[Clip]:
    metadata_path = dataset_path / "meta" / "esc50.csv"
    with metadata_path.open(newline="", encoding="utf-8") as file:
        rows = list(csv.DictReader(file))

    selected: list[Clip] = []
    counts: dict[tuple[int, int], int] = {}
    for row in sorted(rows, key=lambda item: (int(item["fold"]), int(item["target"]), item["filename"])):
        fold = int(row["fold"])
        target = int(row["target"])
        if folds is not None and fold not in folds:
            continue
        key = (fold, target)
        if limit_per_class is not None and counts.get(key, 0) >= limit_per_class:
            continue
        selected.append(
            Clip(
                filename=row["filename"],
                fold=fold,
                target=target,
                category=row["category"],
            )
        )
        counts[key] = counts.get(key, 0) + 1
    if not selected:
        raise ValueError("no clips selected")
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
    return np.frombuffer(result.stdout, dtype="<f4").astype(np.float32)


class Yamnet:
    def __init__(self, model_path: Path, labels: list[str], aggregation: str) -> None:
        self.interpreter = Interpreter(model_path=str(model_path))
        self.interpreter.allocate_tensors()
        self.labels = labels
        self.aggregation = aggregation
        self.scores_output_index = self._resolve_scores_output_index()
        self.input_index = int(self.interpreter.get_input_details()[0]["index"])

    def predict_clip_scores(self, samples: np.ndarray) -> np.ndarray:
        self.interpreter.resize_tensor_input(self.input_index, [len(samples)], strict=False)
        self.interpreter.allocate_tensors()
        self.interpreter.set_tensor(self.input_index, samples)
        self.interpreter.invoke()
        frame_scores = np.asarray(
            self.interpreter.get_tensor(self.scores_output_index), dtype=np.float32
        )
        if frame_scores.ndim == 1:
            clip_scores = frame_scores
        elif self.aggregation == "max":
            clip_scores = frame_scores.max(axis=0)
        else:
            clip_scores = frame_scores.mean(axis=0)
        if clip_scores.shape != (len(self.labels),):
            raise ValueError(
                f"unexpected score shape: {clip_scores.shape}, labels={len(self.labels)}"
            )
        return clip_scores

    def _resolve_scores_output_index(self) -> int:
        for detail in self.interpreter.get_output_details():
            shape = tuple(detail["shape"])
            if len(shape) == 2 and shape[-1] == 521:
                return int(detail["index"])
        raise ValueError("could not locate YAMNet scores output [*, 521]")


def category_scores(scores: np.ndarray, indices: dict[str, list[int]]) -> dict[str, float]:
    return {
        category: float(scores[label_indices].max())
        for category, label_indices in indices.items()
    }


def top_yamnet(scores: np.ndarray, labels: list[str], count: int = 10) -> list[dict[str, float | str]]:
    order = np.argsort(scores)[::-1][:count]
    return [
        {"label": labels[int(index)], "score": float(scores[int(index)])}
        for index in order
    ]


def summarize_results(results: list[dict], categories: set[str] | None = None) -> dict[str, float | int]:
    subset = [
        item
        for item in results
        if categories is None or item["actual_category"] in categories
    ]
    count = len(subset)
    if count == 0:
        return {"count": 0}
    return {
        "count": count,
        "fine_accuracy_at_1": sum(item["fine_rank"] <= 1 for item in subset) / count,
        "fine_accuracy_at_3": sum(item["fine_rank"] <= 3 for item in subset) / count,
        "fine_accuracy_at_5": sum(item["fine_rank"] <= 5 for item in subset) / count,
        "coarse_accuracy_at_1": sum(item["coarse_correct"] for item in subset) / count,
    }


def evaluate(
    clips: list[Clip],
    model: Yamnet,
    dataset_path: Path,
    indices: dict[str, list[int]],
) -> tuple[list[dict], float]:
    results: list[dict] = []
    started = time.perf_counter()
    for index, clip in enumerate(clips, 1):
        print(f"predict {index:4d}/{len(clips)}: {clip.filename}", flush=True)
        scores = model.predict_clip_scores(
            decode_audio(dataset_path / "audio" / clip.filename)
        )
        scores_by_category = category_scores(scores, indices)
        ranked = sorted(scores_by_category.items(), key=lambda item: item[1], reverse=True)
        fine_rank = 1 + [category for category, _ in ranked].index(clip.category)
        predicted_category = ranked[0][0]
        predicted_target = category_to_target(predicted_category)
        results.append(
            {
                "filename": clip.filename,
                "fold": clip.fold,
                "actual_category": clip.category,
                "actual_coarse_category": clip.coarse_category,
                "predicted_category": predicted_category,
                "predicted_coarse_category": COARSE_CATEGORIES[predicted_target // 10],
                "coarse_correct": COARSE_CATEGORIES[predicted_target // 10] == clip.coarse_category,
                "fine_rank": fine_rank,
                "actual_category_score": scores_by_category[clip.category],
                "top_categories": [
                    {"category": category, "score": score}
                    for category, score in ranked[:10]
                ],
                "top_yamnet_labels": top_yamnet(scores, model.labels),
                "direct_label_mapping": clip.category in DIRECT_CATEGORIES,
            }
        )
    return results, time.perf_counter() - started


def category_to_target(category: str) -> int:
    categories = list(ESC50_TO_YAMNET)
    return categories.index(category)


def write_report(
    output_path: Path,
    clips: list[Clip],
    results: list[dict],
    elapsed: float,
    aggregation: str,
) -> dict:
    report = {
        "configuration": {
            "dataset": "ESC-50",
            "dataset_revision": ESC50_COMMIT,
            "dataset_archive_url": ESC50_ARCHIVE_URL,
            "model": "YAMNet TFLite",
            "model_url": MODEL_URL,
            "model_sha256": MODEL_SHA256,
            "class_map_url": CLASS_MAP_URL,
            "class_map_revision": CLASS_MAP_COMMIT,
            "class_map_sha256": CLASS_MAP_SHA256,
            "sample_rate": SAMPLE_RATE,
            "aggregation": aggregation,
            "clip_count": len(clips),
            "folds": sorted({clip.fold for clip in clips}),
            "direct_label_categories": sorted(DIRECT_CATEGORIES),
            "python": sys.version.split()[0],
            "platform": platform.platform(),
            "numpy": np.__version__,
            "ai_edge_litert": metadata.version("ai-edge-litert"),
        },
        "metrics": {
            "all": summarize_results(results),
            "direct_label_mapping": summarize_results(results, DIRECT_CATEGORIES),
            "elapsed_seconds": elapsed,
            "seconds_per_clip": elapsed / len(clips),
        },
        "results": results,
    }
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return report


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-dir", type=Path, default=Path("models"))
    parser.add_argument("--data-dir", type=Path, default=Path("data"))
    parser.add_argument("--output", type=Path, default=Path("output/report.json"))
    parser.add_argument("--aggregation", choices=("mean", "max"), default="mean")
    parser.add_argument("--folds", type=int, nargs="*", choices=range(1, 6))
    parser.add_argument("--limit-per-class", type=int)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    model_path, class_map_path, dataset_path = prepare_resources(args.model_dir, args.data_dir)
    labels = load_labels(class_map_path)
    indices = label_indices(labels)
    folds = set(args.folds) if args.folds else None
    clips = load_clips(dataset_path, folds, args.limit_per_class)
    model = Yamnet(model_path, labels, args.aggregation)
    results, elapsed = evaluate(clips, model, dataset_path, indices)
    report = write_report(args.output, clips, results, elapsed, args.aggregation)
    print(json.dumps(report["metrics"], ensure_ascii=False, indent=2))
    print(f"report: {args.output}")


if __name__ == "__main__":
    main()
