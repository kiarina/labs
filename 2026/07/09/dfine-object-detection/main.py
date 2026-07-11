import hashlib
import json
import statistics
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import cv2
import httpx
import numpy as np
import onnxruntime as ort

MODEL_REVISION = "a3cf03147a9b86c78475139115c8ac142577352d"
MODEL_URL = (
    "https://huggingface.co/onnx-community/dfine_s_coco-ONNX/"
    f"resolve/{MODEL_REVISION}/onnx/model.onnx"
)
MODEL_SHA256 = "cd8a49a945feda6d28c6304ae8ae85c2759ba1d78a5a83a22c5ce8db82ef7238"
CONFIG_URL = (
    "https://huggingface.co/onnx-community/dfine_s_coco-ONNX/"
    f"resolve/{MODEL_REVISION}/config.json"
)
CONFIG_SHA256 = "9338ef3863d6e95627d4ab06009fa85b1dd523b346b5c3595de2b08862136e99"

INPUT_SIZE = 640
SCORE_THRESHOLD = 0.5
BENCHMARK_ITERATIONS = 20
IMAGE_PATH = Path(__file__).resolve().parents[4] / "tests/assets/jpg/objects_1536x1024_358kb.jpg"
OUTPUT_PATH = Path(__file__).parent / "output_detections.png"


@dataclass(frozen=True)
class Detection:
    label: str
    score: float
    bbox: tuple[int, int, int, int]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_file(url: str, path: Path, expected_sha256: str) -> None:
    if path.exists() and sha256_file(path) == expected_sha256:
        return

    if path.exists():
        path.unlink()

    print(f"Downloading {path.name} from {url} ...")
    with httpx.stream("GET", url, follow_redirects=True, timeout=120.0) as response:
        response.raise_for_status()
        with open(path, "wb") as file:
            for chunk in response.iter_bytes(chunk_size=1024 * 1024):
                file.write(chunk)

    actual_sha256 = sha256_file(path)
    if actual_sha256 != expected_sha256:
        path.unlink(missing_ok=True)
        raise RuntimeError(
            f"SHA-256 mismatch for {path.name}: "
            f"expected {expected_sha256}, got {actual_sha256}"
        )


def load_labels(config_path: Path) -> list[str]:
    with open(config_path, encoding="utf-8") as file:
        config = json.load(file)

    id_to_label = {int(key): value for key, value in config["id2label"].items()}
    return [id_to_label[index] for index in range(len(id_to_label))]


def sigmoid(values: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-values))


def prepare_image(image_bgr: np.ndarray) -> np.ndarray:
    resized = cv2.resize(image_bgr, (INPUT_SIZE, INPUT_SIZE), interpolation=cv2.INTER_LINEAR)
    image_rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
    image = image_rgb.astype(np.float32) / 255.0
    return np.transpose(image, (2, 0, 1))[np.newaxis, ...]


def run_model(session: ort.InferenceSession, image_bgr: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    input_name = session.get_inputs()[0].name
    outputs = session.run(None, {input_name: prepare_image(image_bgr)})
    output_by_name = {
        output.name: index for index, output in enumerate(session.get_outputs())
    }
    logits_output = np.asarray(outputs[output_by_name["logits"]])
    logits = logits_output.reshape(-1, logits_output.shape[-1])
    boxes = np.asarray(outputs[output_by_name["pred_boxes"]]).reshape(-1, 4)
    return logits, boxes


def detect(
    session: ort.InferenceSession,
    labels: list[str],
    image_bgr: np.ndarray,
) -> list[Detection]:
    logits, boxes = run_model(session, image_bgr)
    scores = sigmoid(logits)
    class_ids = scores.argmax(axis=1)
    best_scores = scores.max(axis=1)
    image_height, image_width = image_bgr.shape[:2]

    detections: list[Detection] = []
    for class_id, score, box in zip(class_ids, best_scores, boxes, strict=True):
        if float(score) < SCORE_THRESHOLD:
            continue

        cx, cy, width, height = (float(value) for value in box)
        x1 = int(round((cx - width / 2) * image_width))
        y1 = int(round((cy - height / 2) * image_height))
        x2 = int(round((cx + width / 2) * image_width))
        y2 = int(round((cy + height / 2) * image_height))
        x1 = max(0, min(image_width - 1, x1))
        y1 = max(0, min(image_height - 1, y1))
        x2 = max(0, min(image_width - 1, x2))
        y2 = max(0, min(image_height - 1, y2))

        if x2 <= x1 or y2 <= y1:
            continue

        label = labels[int(class_id)] if 0 <= int(class_id) < len(labels) else str(class_id)
        detections.append(Detection(label=label, score=float(score), bbox=(x1, y1, x2, y2)))

    return sorted(detections, key=lambda detection: detection.score, reverse=True)


def draw_detections(image_bgr: np.ndarray, detections: list[Detection], output_path: Path) -> None:
    output = image_bgr.copy()
    for detection in detections:
        x1, y1, x2, y2 = detection.bbox
        cv2.rectangle(output, (x1, y1), (x2, y2), (0, 220, 0), 2)
        text = f"{detection.label} {detection.score:.2f}"
        (text_width, text_height), baseline = cv2.getTextSize(
            text, cv2.FONT_HERSHEY_SIMPLEX, 0.55, 2
        )
        text_y = max(text_height + baseline + 2, y1)
        cv2.rectangle(
            output,
            (x1, text_y - text_height - baseline - 4),
            (x1 + text_width + 6, text_y + baseline - 2),
            (0, 220, 0),
            thickness=-1,
        )
        cv2.putText(
            output,
            text,
            (x1 + 3, text_y - 4),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.55,
            (0, 0, 0),
            2,
            cv2.LINE_AA,
        )

    cv2.imwrite(str(output_path), output)


def benchmark(session: ort.InferenceSession, image_bgr: np.ndarray) -> tuple[float, float, float, float]:
    for _ in range(3):
        detect(session, [], image_bgr)

    times_ms: list[float] = []
    for _ in range(BENCHMARK_ITERATIONS):
        started_at = time.perf_counter()
        detect(session, [], image_bgr)
        times_ms.append((time.perf_counter() - started_at) * 1000)

    return (
        statistics.mean(times_ms),
        min(times_ms),
        max(times_ms),
        statistics.stdev(times_ms) if len(times_ms) > 1 else 0.0,
    )


def main() -> int:
    base_dir = Path(__file__).parent
    model_path = base_dir / "model.onnx"
    config_path = base_dir / "config.json"

    if not IMAGE_PATH.exists():
        print(
            f"Input image not found: {IMAGE_PATH}\n"
            "Run `make download-test-assets` from the repository root first.",
            file=sys.stderr,
        )
        return 1

    ensure_file(MODEL_URL, model_path, MODEL_SHA256)
    ensure_file(CONFIG_URL, config_path, CONFIG_SHA256)

    labels = load_labels(config_path)
    image_bgr = cv2.imread(str(IMAGE_PATH))
    if image_bgr is None:
        print(f"Failed to load image: {IMAGE_PATH}", file=sys.stderr)
        return 1

    session = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
    detections = detect(session, labels, image_bgr)
    average_ms, min_ms, max_ms, stdev_ms = benchmark(session, image_bgr)
    draw_detections(image_bgr, detections, OUTPUT_PATH)

    print("--- Input ---")
    print(f"Image:      {IMAGE_PATH}")
    print(f"Resolution: {image_bgr.shape[1]}x{image_bgr.shape[0]}")
    print(f"Threshold:  {SCORE_THRESHOLD:.2f}")

    print("\n--- Detections ---")
    print(f"{'Rank':>4} | {'Label':<16} | {'Score':>5} | BBox xyxy")
    print("-" * 56)
    for index, detection in enumerate(detections, start=1):
        x1, y1, x2, y2 = detection.bbox
        print(
            f"{index:>4} | {detection.label:<16} | {detection.score:>5.3f} | "
            f"({x1}, {y1}, {x2}, {y2})"
        )

    print(f"\nDetection count: {len(detections)}")

    print(f"\n--- Inference Speed Benchmark (Iterations: {BENCHMARK_ITERATIONS}) ---")
    print(f"Average time: {average_ms:.2f} ms")
    print(f"Min time:     {min_ms:.2f} ms")
    print(f"Max time:     {max_ms:.2f} ms")
    print(f"Std dev:      {stdev_ms:.2f} ms")

    print("\n--- Visualization ---")
    print(f"Saved: {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
