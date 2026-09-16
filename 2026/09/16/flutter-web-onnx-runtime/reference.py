"""Prepare the Flutter Web lab and record the native ONNX Runtime reference.

- Downloads the D-FINE model and config into web/models/ (SHA-256 verified)
- Copies the shared input image into assets/
- Writes model_ceil0.onnx, a copy whose MaxPool ceil_mode is 0 (see README)
- Runs the same preprocessing and model with native ONNX Runtime (CPU)
- Writes the decoded pixels and reference input/outputs to web/reference/ for the browser to compare
"""

import hashlib
import json
import platform
import shutil
import statistics
import sys
import time
import urllib.request
from pathlib import Path

import cv2
import numpy as np
import onnx
import onnxruntime as ort

MODEL_REVISION = "a3cf03147a9b86c78475139115c8ac142577352d"
BASE_URL = f"https://huggingface.co/onnx-community/dfine_s_coco-ONNX/resolve/{MODEL_REVISION}"
FILES = {
    "model.onnx": (
        f"{BASE_URL}/onnx/model.onnx",
        "cd8a49a945feda6d28c6304ae8ae85c2759ba1d78a5a83a22c5ce8db82ef7238",
    ),
    "config.json": (
        f"{BASE_URL}/config.json",
        "9338ef3863d6e95627d4ab06009fa85b1dd523b346b5c3595de2b08862136e99",
    ),
}

INPUT_SIZE = 640
SCORE_THRESHOLD = 0.5
WARMUP = 3
ITERATIONS = 20

LAB_DIR = Path(__file__).resolve().parent
REPO_ROOT = LAB_DIR.parents[3]
IMAGE_NAME = "objects_1536x1024_358kb.jpg"
IMAGE_SHA256 = "aa973bb3f6283f30ec863cf21eeeca446d939715f6da168651c7c48fc7d935c5"
IMAGE_SOURCE = REPO_ROOT / "tests/assets/jpg" / IMAGE_NAME
MODELS_DIR = LAB_DIR / "web/models"
REFERENCE_DIR = LAB_DIR / "web/reference"
ASSETS_DIR = LAB_DIR / "assets"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_file(url: str, path: Path, expected_sha256: str) -> None:
    if path.exists() and sha256_file(path) == expected_sha256:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {path.name} ...")
    tmp_path = path.with_suffix(path.suffix + ".tmp")
    urllib.request.urlretrieve(url, tmp_path)
    actual = sha256_file(tmp_path)
    if actual != expected_sha256:
        tmp_path.unlink(missing_ok=True)
        raise RuntimeError(f"SHA-256 mismatch for {path.name}: {actual}")
    tmp_path.replace(path)


def write_ceil0_model(src: Path, dst: Path) -> list[str]:
    """Set ceil_mode=0 on MaxPool nodes where it cannot change the output shape.

    The ONNX Runtime Web WebGPU MaxPool kernel rejects ceil_mode=1. With stride 1
    and no padding, ceil and floor give the same output size, so the graph is
    equivalent.
    """
    model = onnx.load(str(src))
    patched = []
    for node in model.graph.node:
        if node.op_type != "MaxPool":
            continue
        attrs = {a.name: a for a in node.attribute}
        if "ceil_mode" not in attrs or attrs["ceil_mode"].i == 0:
            continue
        strides = list(attrs["strides"].ints) if "strides" in attrs else [1, 1]
        pads = list(attrs["pads"].ints) if "pads" in attrs else [0, 0, 0, 0]
        if any(v != 1 for v in strides) or any(pads):
            raise RuntimeError(f"{node.name}: ceil_mode may change the output shape")
        attrs["ceil_mode"].i = 0
        patched.append(node.name)
    onnx.save(model, str(dst))
    return patched


def prepare_image(image_bgr: np.ndarray) -> np.ndarray:
    resized = cv2.resize(image_bgr, (INPUT_SIZE, INPUT_SIZE), interpolation=cv2.INTER_LINEAR)
    image_rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
    image = image_rgb.astype(np.float32) / 255.0
    return np.ascontiguousarray(np.transpose(image, (2, 0, 1))[np.newaxis, ...])


def detect(logits: np.ndarray, boxes: np.ndarray, labels: list[str], width: int, height: int) -> list[dict]:
    scores = 1.0 / (1.0 + np.exp(-logits.reshape(-1, logits.shape[-1])))
    detections = []
    for class_id, score, box in zip(scores.argmax(axis=1), scores.max(axis=1), boxes.reshape(-1, 4)):
        if float(score) < SCORE_THRESHOLD:
            continue
        cx, cy, w, h = (float(v) for v in box)
        x1 = max(0, min(width - 1, int(round((cx - w / 2) * width))))
        y1 = max(0, min(height - 1, int(round((cy - h / 2) * height))))
        x2 = max(0, min(width - 1, int(round((cx + w / 2) * width))))
        y2 = max(0, min(height - 1, int(round((cy + h / 2) * height))))
        if x2 <= x1 or y2 <= y1:
            continue
        detections.append(
            {"label": labels[int(class_id)], "score": float(score), "bbox": [x1, y1, x2, y2]}
        )
    return sorted(detections, key=lambda d: d["score"], reverse=True)


def main() -> int:
    if not IMAGE_SOURCE.exists():
        print(f"Input image not found: {IMAGE_SOURCE.relative_to(REPO_ROOT)}", file=sys.stderr)
        return 1
    if sha256_file(IMAGE_SOURCE) != IMAGE_SHA256:
        print("Input image SHA-256 mismatch", file=sys.stderr)
        return 1

    for name, (url, sha256) in FILES.items():
        ensure_file(url, MODELS_DIR / name, sha256)
    ASSETS_DIR.mkdir(exist_ok=True)
    shutil.copyfile(IMAGE_SOURCE, ASSETS_DIR / IMAGE_NAME)
    shutil.copyfile(MODELS_DIR / "config.json", ASSETS_DIR / "config.json")

    config = json.loads((MODELS_DIR / "config.json").read_text(encoding="utf-8"))
    labels = [config["id2label"][str(i)] for i in range(len(config["id2label"]))]

    image_bgr = cv2.imread(str(IMAGE_SOURCE))
    height, width = image_bgr.shape[:2]
    session = ort.InferenceSession(str(MODELS_DIR / "model.onnx"), providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    output_names = [o.name for o in session.get_outputs()]

    patched_nodes = write_ceil0_model(MODELS_DIR / "model.onnx", MODELS_DIR / "model_ceil0.onnx")
    ceil0_session = ort.InferenceSession(
        str(MODELS_DIR / "model_ceil0.onnx"), providers=["CPUExecutionProvider"]
    )

    tensor = prepare_image(image_bgr)
    outputs = dict(zip(output_names, session.run(None, {input_name: tensor})))
    ceil0_outputs = dict(zip(output_names, ceil0_session.run(None, {input_name: tensor})))
    ceil0_max_diff = max(
        float(np.abs(outputs[name] - ceil0_outputs[name]).max()) for name in output_names
    )
    detections = detect(outputs["logits"], outputs["pred_boxes"], labels, width, height)

    for _ in range(WARMUP):
        session.run(None, {input_name: prepare_image(image_bgr)})
    times = []
    for _ in range(ITERATIONS):
        started = time.perf_counter()
        t = prepare_image(image_bgr)
        o = session.run(None, {input_name: t})
        detect(o[output_names.index("logits")], o[output_names.index("pred_boxes")], labels, width, height)
        times.append((time.perf_counter() - started) * 1000)

    REFERENCE_DIR.mkdir(parents=True, exist_ok=True)
    cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB).tofile(REFERENCE_DIR / "decoded_rgb.bin")
    tensor.astype("<f4").tofile(REFERENCE_DIR / "input.bin")
    outputs["logits"].astype("<f4").tofile(REFERENCE_DIR / "logits.bin")
    outputs["pred_boxes"].astype("<f4").tofile(REFERENCE_DIR / "pred_boxes.bin")
    summary = {
        "runtime": f"onnxruntime {ort.__version__} (Python, CPUExecutionProvider)",
        "opencv": cv2.__version__,
        "machine": platform.platform(),
        "input": {"name": input_name, "shape": list(tensor.shape)},
        "outputs": {name: list(value.shape) for name, value in outputs.items()},
        "ceil0_model": {"patched_nodes": patched_nodes, "max_abs_diff_vs_original": ceil0_max_diff},
        "detections": detections,
        "benchmark_ms": {
            "iterations": ITERATIONS,
            "mean": statistics.mean(times),
            "min": min(times),
            "max": max(times),
            "stdev": statistics.stdev(times),
        },
    }
    (REFERENCE_DIR / "reference.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
