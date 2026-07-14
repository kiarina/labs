import hashlib
import platform
import statistics
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import onnx
import onnxruntime as ort
import torch
import ultralytics
from ultralytics import YOLO

LAB_DIR = Path(__file__).parent
IMAGE_PATH = (
    Path(__file__).resolve().parents[4]
    / "tests/assets/jpg/street_scene_1774x887_287kb.jpg"
)
PT_MODEL_PATH = LAB_DIR / "yolo26n-sem.pt"
ONNX_MODEL_PATH = LAB_DIR / "yolo26n-sem.onnx"
PT_MODEL_SHA256 = "f3f293cca764de1f93044030d8d5612de9c5ffbf37c9c8ea1b69418b73038999"
INPUT_SIZE = 640
WARMUP_ITERATIONS = 3
BENCHMARK_ITERATIONS = 10
CITYSCAPES_COLORS_RGB = [
    (128, 64, 128),
    (244, 35, 232),
    (70, 70, 70),
    (102, 102, 156),
    (190, 153, 153),
    (153, 153, 153),
    (250, 170, 30),
    (220, 220, 0),
    (107, 142, 35),
    (152, 251, 152),
    (70, 130, 180),
    (220, 20, 60),
    (255, 0, 0),
    (0, 0, 142),
    (0, 0, 70),
    (0, 60, 100),
    (0, 80, 100),
    (0, 0, 230),
    (119, 11, 32),
]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_pytorch_model() -> YOLO:
    model = YOLO(PT_MODEL_PATH.name)
    actual_sha256 = sha256_file(PT_MODEL_PATH)
    if actual_sha256 != PT_MODEL_SHA256:
        raise RuntimeError(
            f"Model SHA-256 mismatch: expected {PT_MODEL_SHA256}, got {actual_sha256}"
        )
    return model


def ensure_onnx_model(model: YOLO) -> None:
    if ONNX_MODEL_PATH.exists():
        return
    exported = model.export(
        format="onnx",
        imgsz=INPUT_SIZE,
        opset=18,
        simplify=False,
        device="cpu",
    )
    if Path(exported).resolve() != ONNX_MODEL_PATH.resolve():
        raise RuntimeError(f"Unexpected ONNX export path: {exported}")


def predict(model: YOLO, image: np.ndarray):
    return model.predict(
        image,
        imgsz=INPUT_SIZE,
        device="cpu",
        rect=False,
        verbose=False,
    )[0]


def benchmark(model: YOLO, image: np.ndarray) -> tuple[object, dict[str, list[float]]]:
    result = None
    for _ in range(WARMUP_ITERATIONS):
        result = predict(model, image)

    measurements = {"preprocess": [], "inference": [], "postprocess": [], "wall": []}
    for _ in range(BENCHMARK_ITERATIONS):
        started_at = time.perf_counter()
        result = predict(model, image)
        measurements["wall"].append((time.perf_counter() - started_at) * 1000.0)
        for stage in ("preprocess", "inference", "postprocess"):
            measurements[stage].append(result.speed[stage])
    return result, measurements


def print_benchmark(name: str, measurements: dict[str, list[float]]) -> None:
    print(f"\n--- {name} benchmark ---")
    for stage in ("preprocess", "inference", "postprocess", "wall"):
        values = measurements[stage]
        print(
            f"{stage.capitalize():11} "
            f"mean={statistics.mean(values):7.2f} ms  "
            f"min={min(values):7.2f} ms  "
            f"max={max(values):7.2f} ms  "
            f"std={statistics.stdev(values):6.2f} ms"
        )


def class_comparison(
    pytorch_mask: np.ndarray, onnx_mask: np.ndarray, names: dict[int, str]
) -> None:
    print("\n--- Class area and agreement ---")
    print("class             PyTorch     ONNX      IoU")
    present = sorted(set(np.unique(pytorch_mask)) | set(np.unique(onnx_mask)))
    for class_id in present:
        pytorch_class = pytorch_mask == class_id
        onnx_class = onnx_mask == class_id
        intersection = np.count_nonzero(pytorch_class & onnx_class)
        union = np.count_nonzero(pytorch_class | onnx_class)
        iou = intersection / union if union else 1.0
        print(
            f"{names[int(class_id)]:16} "
            f"{pytorch_class.mean() * 100:7.2f}%  "
            f"{onnx_class.mean() * 100:7.2f}%  "
            f"{iou * 100:7.2f}%"
        )


def make_explanation_image(
    image: np.ndarray, mask: np.ndarray, names: dict[int, str]
) -> np.ndarray:
    height, width = image.shape[:2]
    palette_bgr = np.asarray(
        [color[::-1] for color in CITYSCAPES_COLORS_RGB], dtype=np.uint8
    )
    color_mask = palette_bgr[mask]
    overlay = cv2.addWeighted(image, 0.5, color_mask, 0.5, 0.0)

    panel_width = 768
    panel_height = round(height * panel_width / width)
    original_panel = cv2.resize(image, (panel_width, panel_height))
    overlay_panel = cv2.resize(overlay, (panel_width, panel_height))
    comparison = np.hstack([original_panel, overlay_panel])

    title_height = 70
    present = sorted(np.unique(mask), key=lambda class_id: -np.mean(mask == class_id))
    legend_rows = (len(present) + 2) // 3
    legend_height = 72 + legend_rows * 48
    canvas = np.full(
        (title_height + panel_height + legend_height, panel_width * 2, 3),
        250,
        dtype=np.uint8,
    )
    canvas[title_height : title_height + panel_height] = comparison
    cv2.putText(
        canvas,
        "Original image",
        (24, 45),
        cv2.FONT_HERSHEY_SIMPLEX,
        1.0,
        (30, 30, 30),
        2,
        cv2.LINE_AA,
    )
    cv2.putText(
        canvas,
        "ONNX class map overlay",
        (panel_width + 24, 45),
        cv2.FONT_HERSHEY_SIMPLEX,
        1.0,
        (30, 30, 30),
        2,
        cv2.LINE_AA,
    )

    legend_top = title_height + panel_height
    cv2.putText(
        canvas,
        "Predicted Cityscapes classes and pixel share",
        (24, legend_top + 38),
        cv2.FONT_HERSHEY_SIMPLEX,
        0.72,
        (30, 30, 30),
        2,
        cv2.LINE_AA,
    )
    for index, class_id in enumerate(present):
        column = index % 3
        row = index // 3
        x = 24 + column * 500
        y = legend_top + 72 + row * 48
        color = tuple(int(value) for value in palette_bgr[int(class_id)])
        cv2.rectangle(canvas, (x, y), (x + 34, y + 28), color, thickness=-1)
        cv2.rectangle(canvas, (x, y), (x + 34, y + 28), (40, 40, 40), thickness=1)
        area = np.mean(mask == class_id) * 100.0
        cv2.putText(
            canvas,
            f"{names[int(class_id)]}: {area:.2f}%",
            (x + 48, y + 23),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.65,
            (30, 30, 30),
            2,
            cv2.LINE_AA,
        )
    return canvas


def save_outputs(pytorch_result, onnx_result, image: np.ndarray) -> None:
    pytorch_mask = pytorch_result.semantic_mask.data.cpu().numpy()
    onnx_mask = onnx_result.semantic_mask.data.cpu().numpy()
    disagreement = pytorch_mask != onnx_mask

    difference_image = image.copy()
    difference_image[disagreement] = (
        difference_image[disagreement].astype(np.float32) * 0.35
        + np.asarray([0, 0, 255], dtype=np.float32) * 0.65
    ).astype(np.uint8)

    outputs = {
        LAB_DIR / "output_pytorch.png": pytorch_result.plot(),
        LAB_DIR / "output_onnx.png": onnx_result.plot(),
        LAB_DIR / "output_disagreement.png": difference_image,
        LAB_DIR / "output_explanation.png": make_explanation_image(
            image, onnx_mask, onnx_result.names
        ),
    }
    for path, output in outputs.items():
        if not cv2.imwrite(str(path), output):
            raise RuntimeError(f"Failed to save {path}")
        print(f"Saved: {path.name}")


def main() -> int:
    if not IMAGE_PATH.exists():
        print(
            f"Input image not found: {IMAGE_PATH}\n"
            "Run `make download-test-assets` from the repository root first.",
            file=sys.stderr,
        )
        return 1

    image = cv2.imread(str(IMAGE_PATH), cv2.IMREAD_COLOR)
    if image is None:
        print(f"Failed to load image: {IMAGE_PATH}", file=sys.stderr)
        return 1

    pytorch_model = load_pytorch_model()
    ensure_onnx_model(pytorch_model)
    onnx_model = YOLO(str(ONNX_MODEL_PATH), task="semantic")

    pytorch_result, pytorch_times = benchmark(pytorch_model, image)
    onnx_result, onnx_times = benchmark(onnx_model, image)
    pytorch_mask = pytorch_result.semantic_mask.data.cpu().numpy()
    onnx_mask = onnx_result.semantic_mask.data.cpu().numpy()

    onnx_graph = onnx.load(ONNX_MODEL_PATH)
    session = ort.InferenceSession(
        str(ONNX_MODEL_PATH), providers=["CPUExecutionProvider"]
    )
    agreement = np.mean(pytorch_mask == onnx_mask)

    print("--- Environment and model ---")
    print(f"Image:              {IMAGE_PATH}")
    print(f"Resolution:         {image.shape[1]}x{image.shape[0]}")
    print(f"Architecture:       {platform.machine()}")
    print(f"MPS available:      {torch.backends.mps.is_available()}")
    print(f"Python:             {platform.python_version()}")
    print(f"Python backend:     PyTorch {torch.__version__}")
    print(f"Ultralytics:        {ultralytics.__version__}")
    print(f"ONNX:               {onnx.__version__}, opset {onnx_graph.opset_import[0].version}")
    print(f"ONNX Runtime:       {ort.__version__}")
    print(f"OpenCV:             {cv2.__version__}")
    print(f"NumPy:              {np.__version__}")
    print(f"ONNX provider:      {session.get_providers()[0]}")
    print(f"Model SHA-256:      {sha256_file(PT_MODEL_PATH)}")
    print(f"PyTorch model size: {PT_MODEL_PATH.stat().st_size / 1024 / 1024:.2f} MiB")
    print(f"ONNX model size:    {ONNX_MODEL_PATH.stat().st_size / 1024 / 1024:.2f} MiB")
    print(f"ONNX input:         {session.get_inputs()[0].shape}")
    print(f"ONNX output:        {session.get_outputs()[0].shape}")
    print(f"Warmup/iterations:  {WARMUP_ITERATIONS}/{BENCHMARK_ITERATIONS}")

    print_benchmark("PyTorch CPU", pytorch_times)
    print_benchmark("ONNX Runtime CPU", onnx_times)
    print(f"\nPixel agreement: {agreement * 100:.4f}%")
    print(f"Disagreement:    {(1.0 - agreement) * 100:.4f}%")
    class_comparison(pytorch_mask, onnx_mask, pytorch_result.names)
    save_outputs(pytorch_result, onnx_result, image)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
