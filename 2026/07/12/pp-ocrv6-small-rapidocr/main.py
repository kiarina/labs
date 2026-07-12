from __future__ import annotations

import importlib.metadata
import platform
import re
import statistics
import time
from pathlib import Path
from typing import NamedTuple

import cv2
import numpy as np
import onnxruntime
import rapidocr
from rapidocr import EngineType, LangDet, LangRec, ModelType, OCRVersion, RapidOCR


IMAGE_PATH = Path(__file__).parent / "../../../../tests/assets/jpg/ocr_1448x1086_242kb.jpg"
OUTPUT_PATH = Path(__file__).parent / "output_ocr.jpg"
WARMUP_ITERATIONS = 3
BENCHMARK_ITERATIONS = 10


class ExpectedText(NamedTuple):
    category: str
    text: str
    fragments: tuple[str, ...] | None = None


EXPECTED_TEXTS = [
    ExpectedText("Japanese", "OCR テストルーム"),
    ExpectedText(
        "English",
        "Please knock before entering",
        ("Please", "knock before", "entering"),
    ),
    ExpectedText("Numbers", "12345"),
    ExpectedText("Japanese and numbers", "在庫確認：ノート12冊／ペン24本"),
    ExpectedText("English and punctuation", "Next review: Friday, 3:45 PM"),
    ExpectedText("Small Japanese", "忘れずに水やり", ("忘れずに", "水やり")),
    ExpectedText("Small English", "Call Ken at 18:00", ("Call Ken", "at 18:00")),
    ExpectedText("Vertical Japanese", "日本語の練習"),
    ExpectedText("Vertical English", "Deep Learning Basics"),
    ExpectedText("Japanese", "取扱注意"),
    ExpectedText("English", "FRAGILE"),
    ExpectedText("Slanted Japanese", "東京都千代田区1-2-3"),
    ExpectedText("Small email", "test@example.com"),
    ExpectedText("Small telephone", "03-1234-5678"),
]


def normalize(text: str) -> str:
    return re.sub(r"[^0-9a-zA-Z\u3040-\u30ff\u3400-\u9fff]", "", text).lower()


def create_engine() -> RapidOCR:
    return RapidOCR(
        params={
            "Det.engine_type": EngineType.ONNXRUNTIME,
            "Det.lang_type": LangDet.CH,
            "Det.model_type": ModelType.SMALL,
            "Det.ocr_version": OCRVersion.PPOCRV6,
            "Rec.engine_type": EngineType.ONNXRUNTIME,
            "Rec.lang_type": LangRec.JAPAN,
            "Rec.model_type": ModelType.SMALL,
            "Rec.ocr_version": OCRVersion.PPOCRV6,
        }
    )


def polygon_string(box: np.ndarray) -> str:
    return " ".join(f"({int(x)},{int(y)})" for x, y in box)


def print_environment() -> None:
    model_dir = Path(rapidocr.__file__).parent / "models"
    model_files = sorted(path.name for path in model_dir.glob("*.onnx"))

    print("--- Environment ---")
    print(f"Machine:       {platform.machine()}")
    print(f"OS:            {platform.platform()}")
    print(f"Python:        {platform.python_version()}")
    print(f"RapidOCR:      {importlib.metadata.version('rapidocr')}")
    print(f"ONNX Runtime:  {onnxruntime.__version__}")
    print(f"OpenCV:        {cv2.__version__}")
    print("Engine:        ONNX Runtime (CPU)")
    print("Detection:     PP-OCRv6-small")
    print("Recognition:   PP-OCRv6-small (Japanese)")
    print("Classification: ch_ppocr_mobile_v2.0_cls_mobile.onnx (RapidOCR default)")
    selected_models = [
        name
        for name in model_files
        if name
        in {
            "PP-OCRv6_det_small.onnx",
            "ch_ppocr_mobile_v2.0_cls_mobile.onnx",
            "PP-OCRv6_rec_small.onnx",
        }
    ]
    print(f"Packaged models: {', '.join(selected_models) or 'not found'}")


def print_results(result: object) -> None:
    boxes = result.boxes if result.boxes is not None else []
    texts = result.txts if result.txts is not None else []
    scores = result.scores if result.scores is not None else []

    print("\n--- OCR Results ---")
    print("Rank | Score | Polygon | Text")
    print("-" * 100)
    for rank, (box, text, score) in enumerate(zip(boxes, texts, scores), start=1):
        print(f"{rank:4d} | {float(score):.3f} | {polygon_string(box)} | {text}")

    numeric_scores = [float(score) for score in scores]
    print("\n--- Summary ---")
    print(f"Detected lines: {len(texts)}")
    if numeric_scores:
        print(f"Mean confidence: {statistics.mean(numeric_scores):.3f}")
        print(f"Min confidence:  {min(numeric_scores):.3f}")
        print(f"Max confidence:  {max(numeric_scores):.3f}")

    normalized_lines = [normalize(text) for text in texts]
    print("\n--- Representative Text Checks ---")
    print("Status | Category | Expected")
    print("-" * 72)
    matches = 0
    for expected in EXPECTED_TEXTS:
        fragments = expected.fragments or (expected.text,)
        matched = all(
            any(normalize(fragment) in line for line in normalized_lines)
            for fragment in fragments
        )
        matches += matched
        print(f"{'PASS' if matched else 'MISS':6s} | {expected.category:23s} | {expected.text}")
    print(f"Matched: {matches}/{len(EXPECTED_TEXTS)}")


def benchmark(engine: RapidOCR, image: np.ndarray) -> None:
    for _ in range(WARMUP_ITERATIONS):
        engine(image)

    times = []
    for _ in range(BENCHMARK_ITERATIONS):
        start = time.perf_counter()
        engine(image)
        times.append((time.perf_counter() - start) * 1000)

    print(f"\n--- OCR Speed Benchmark (Iterations: {BENCHMARK_ITERATIONS}) ---")
    print(f"Average time: {statistics.mean(times):.2f} ms")
    print(f"Min time:     {min(times):.2f} ms")
    print(f"Max time:     {max(times):.2f} ms")
    print(f"Std dev:      {statistics.stdev(times):.2f} ms")


def main() -> None:
    if not IMAGE_PATH.exists():
        raise FileNotFoundError(f"Input image not found: {IMAGE_PATH}")

    image = cv2.imread(str(IMAGE_PATH))
    if image is None:
        raise RuntimeError(f"Failed to read input image: {IMAGE_PATH}")

    print_environment()
    print("\n--- Input ---")
    print("Image:      tests/assets/jpg/ocr_1448x1086_242kb.jpg")
    print(f"Resolution: {image.shape[1]}x{image.shape[0]}")

    engine = create_engine()
    result = engine(image)
    print_results(result)
    benchmark(engine, image)

    result.vis(str(OUTPUT_PATH))
    print(f"\nVisualization: {OUTPUT_PATH.name}")


if __name__ == "__main__":
    main()
