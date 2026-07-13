import hashlib
import statistics
import sys
import time
from pathlib import Path

import cv2
import httpx
import numpy as np
import onnxruntime as ort

MODEL_URL = (
    "https://github.com/ZhengPeng7/BiRefNet/releases/download/v1/"
    "BiRefNet-general-bb_swin_v1_tiny-epoch_232.onnx"
)
MODEL_SHA256 = "5600024376f572a557870a5eb0afb1e5961636bef4e1e22132025467d0f03333"
INPUT_SIZE = 1024
WARMUP_ITERATIONS = 3
BENCHMARK_ITERATIONS = 10
IMAGE_PATH = (
    Path(__file__).resolve().parents[4]
    / "tests/assets/jpg/removebg_1536x1024_141kb.jpg"
)
OUTPUT_PATH = Path(__file__).parent / "output_removed_bg.png"
MEAN = np.asarray([0.485, 0.456, 0.406], dtype=np.float32).reshape(1, 1, 3)
STD = np.asarray([0.229, 0.224, 0.225], dtype=np.float32).reshape(1, 1, 3)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_model(path: Path) -> None:
    if path.exists() and sha256_file(path) == MODEL_SHA256:
        return

    path.unlink(missing_ok=True)
    print(f"Downloading {path.name} from {MODEL_URL} ...")
    with httpx.stream("GET", MODEL_URL, follow_redirects=True, timeout=300.0) as response:
        response.raise_for_status()
        with path.open("wb") as file:
            for chunk in response.iter_bytes(chunk_size=1024 * 1024):
                file.write(chunk)

    actual_sha256 = sha256_file(path)
    if actual_sha256 != MODEL_SHA256:
        path.unlink(missing_ok=True)
        raise RuntimeError(
            f"SHA-256 mismatch: expected {MODEL_SHA256}, got {actual_sha256}"
        )


def prepare_image(image_bgr: np.ndarray) -> np.ndarray:
    resized = cv2.resize(
        image_bgr, (INPUT_SIZE, INPUT_SIZE), interpolation=cv2.INTER_LINEAR
    )
    image_rgb = cv2.cvtColor(resized, cv2.COLOR_BGR2RGB)
    normalized = (image_rgb.astype(np.float32) / 255.0 - MEAN) / STD
    return np.transpose(normalized, (2, 0, 1))[np.newaxis, ...]


def sigmoid(values: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-np.clip(values, -80.0, 80.0)))


def make_output(image_bgr: np.ndarray, logits: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    mask = sigmoid(np.asarray(logits).squeeze())
    height, width = image_bgr.shape[:2]
    mask = cv2.resize(mask, (width, height), interpolation=cv2.INTER_LINEAR)
    alpha = np.clip(np.rint(mask * 255.0), 0, 255).astype(np.uint8)
    output_bgra = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2BGRA)
    output_bgra[:, :, 3] = alpha
    return output_bgra, alpha


def benchmark(session: ort.InferenceSession, input_tensor: np.ndarray) -> list[float]:
    input_name = session.get_inputs()[0].name
    for _ in range(WARMUP_ITERATIONS):
        session.run(None, {input_name: input_tensor})

    times_ms: list[float] = []
    for _ in range(BENCHMARK_ITERATIONS):
        started_at = time.perf_counter()
        session.run(None, {input_name: input_tensor})
        times_ms.append((time.perf_counter() - started_at) * 1000.0)
    return times_ms


def main() -> int:
    model_path = Path(__file__).parent / "model.onnx"
    if not IMAGE_PATH.exists():
        print(
            f"Input image not found: {IMAGE_PATH}\n"
            "Run `make download-test-assets` from the repository root first.",
            file=sys.stderr,
        )
        return 1

    ensure_model(model_path)
    image_bgr = cv2.imread(str(IMAGE_PATH), cv2.IMREAD_COLOR)
    if image_bgr is None:
        print(f"Failed to load image: {IMAGE_PATH}", file=sys.stderr)
        return 1

    session = ort.InferenceSession(str(model_path), providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name

    total_started_at = time.perf_counter()
    started_at = time.perf_counter()
    input_tensor = prepare_image(image_bgr)
    preprocessing_ms = (time.perf_counter() - started_at) * 1000.0

    started_at = time.perf_counter()
    logits = session.run(None, {input_name: input_tensor})[-1]
    inference_ms = (time.perf_counter() - started_at) * 1000.0

    started_at = time.perf_counter()
    output_bgra, alpha = make_output(image_bgr, logits)
    postprocessing_ms = (time.perf_counter() - started_at) * 1000.0

    started_at = time.perf_counter()
    if not cv2.imwrite(str(OUTPUT_PATH), output_bgra):
        print(f"Failed to save image: {OUTPUT_PATH}", file=sys.stderr)
        return 1
    save_ms = (time.perf_counter() - started_at) * 1000.0
    total_ms = (time.perf_counter() - total_started_at) * 1000.0

    times_ms = benchmark(session, input_tensor)
    transparent = np.count_nonzero(alpha == 0) / alpha.size * 100.0
    opaque = np.count_nonzero(alpha == 255) / alpha.size * 100.0
    transition = np.count_nonzero((alpha > 0) & (alpha < 255)) / alpha.size * 100.0

    print("--- Input and model ---")
    print(f"Image:       {IMAGE_PATH}")
    print(f"Resolution:  {image_bgr.shape[1]}x{image_bgr.shape[0]}")
    print(f"Model input: {session.get_inputs()[0].shape}")
    print(f"Model output: {session.get_outputs()[-1].shape}")
    print(f"Provider:    {session.get_providers()[0]}")

    print("\n--- One-shot processing time ---")
    print(f"Preprocessing:  {preprocessing_ms:.2f} ms")
    print(f"Inference:      {inference_ms:.2f} ms")
    print(f"Postprocessing: {postprocessing_ms:.2f} ms")
    print(f"PNG save:       {save_ms:.2f} ms")
    print(f"Total:          {total_ms:.2f} ms")

    print(
        f"\n--- Inference benchmark "
        f"(Warmup: {WARMUP_ITERATIONS}, Iterations: {BENCHMARK_ITERATIONS}) ---"
    )
    print(f"Average time: {statistics.mean(times_ms):.2f} ms")
    print(f"Min time:     {min(times_ms):.2f} ms")
    print(f"Max time:     {max(times_ms):.2f} ms")
    print(f"Std dev:      {statistics.stdev(times_ms):.2f} ms")

    print("\n--- Alpha mask ---")
    print(f"Transparent (alpha=0):   {transparent:.2f}%")
    print(f"Transition (1-254):      {transition:.2f}%")
    print(f"Opaque (alpha=255):      {opaque:.2f}%")
    print(f"Saved: {OUTPUT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
