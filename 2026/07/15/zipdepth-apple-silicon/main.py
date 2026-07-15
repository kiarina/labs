import hashlib
import statistics
import time
from pathlib import Path

import cv2
import httpx
import matplotlib
import numpy as np
import onnx
import onnxruntime as ort
import torch
import torch.nn.functional as F

from zipdepth.model.architecture import create_model
from zipdepth.utils.model_utils import (
    fuse_remaining_conv_bn,
    strip_state_dict_prefixes,
)

matplotlib.use("Agg")
from matplotlib import pyplot as plt  # noqa: E402

ROOT = Path(__file__).resolve().parents[4]
LAB_DIR = Path(__file__).parent
ASSET_DIR = ROOT / "tests/assets/jpg"
OUTPUT_DIR = LAB_DIR / "output"
INPUT_SIZE = 384
SIZE_DIVISOR = 32
WARMUP_ITERATIONS = 3
BENCHMARK_ITERATIONS = 10
ZIPDEPTH_COMMIT = "a302e5437bc58f15c4efd41d3e8222bf24f7d470"
CHECKPOINTS = {
    "standard": (
        "https://github.com/fabiotosi92/ZipDepth/raw/"
        f"{ZIPDEPTH_COMMIT}/checkpoints/zipdepth_base.pth",
        "a55910bb0b99c8c5e641cb9206e810b269690ad94e8a2ef08c827c4679391a65",
    ),
    "npu": (
        "https://github.com/fabiotosi92/ZipDepth/raw/"
        f"{ZIPDEPTH_COMMIT}/checkpoints/zipdepth_base_npu.pth",
        "627c04fda584133ead4310074884a4a037061b4c01ba86e73e492ea30fab570d",
    ),
}
IMAGES = [
    ASSET_DIR / "street_scene_1774x887_287kb.jpg",
    ASSET_DIR / "objects_1536x1024_358kb.jpg",
    ASSET_DIR / "many_face_1280x720_275kb.jpg",
]


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_checkpoint(kind: str) -> Path:
    url, expected_sha256 = CHECKPOINTS[kind]
    path = LAB_DIR / f"zipdepth_base{'_npu' if kind == 'npu' else ''}.pth"
    if path.exists() and sha256_file(path) == expected_sha256:
        return path
    path.unlink(missing_ok=True)
    print(f"Downloading {path.name} ...")
    with httpx.stream("GET", url, follow_redirects=True, timeout=300.0) as response:
        response.raise_for_status()
        with path.open("wb") as file:
            for chunk in response.iter_bytes(1024 * 1024):
                file.write(chunk)
    actual_sha256 = sha256_file(path)
    if actual_sha256 != expected_sha256:
        path.unlink(missing_ok=True)
        raise RuntimeError(
            f"SHA-256 mismatch for {path.name}: {actual_sha256}"
        )
    return path


def make_divisible(value: float) -> int:
    return max(SIZE_DIVISOR, round(value / SIZE_DIVISOR) * SIZE_DIVISOR)


def prepare_image(path: Path) -> tuple[np.ndarray, np.ndarray]:
    image_bgr = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if image_bgr is None:
        raise RuntimeError(f"Failed to load {path}")
    image_rgb = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2RGB)
    height, width = image_rgb.shape[:2]
    scale = INPUT_SIZE / min(height, width)
    target_height = make_divisible(height * scale)
    target_width = make_divisible(width * scale)
    resized = cv2.resize(
        image_rgb, (target_width, target_height), interpolation=cv2.INTER_LINEAR
    )
    tensor = np.transpose(resized.astype(np.float32) / 255.0, (2, 0, 1))[None]
    return resized, tensor


def load_model(checkpoint: Path, device: torch.device, *, npu: bool) -> torch.nn.Module:
    model = create_model(variant="base", upsample_unfold=not npu)
    state = torch.load(checkpoint, map_location="cpu", weights_only=True)
    state = strip_state_dict_prefixes(state.get("model_state_dict", state))
    missing, unexpected = model.load_state_dict(state, strict=False)
    if missing or unexpected:
        raise RuntimeError(f"Checkpoint mismatch: missing={missing}, unexpected={unexpected}")
    model.eval()
    model.fuse_for_inference()
    fuse_remaining_conv_bn(model)
    return model.to(device)


def synchronize(device: torch.device) -> None:
    if device.type == "mps":
        torch.mps.synchronize()


def benchmark_torch(
    model: torch.nn.Module, input_array: np.ndarray, device: torch.device
) -> tuple[np.ndarray, list[float]]:
    tensor = torch.from_numpy(input_array).to(device)
    with torch.inference_mode():
        for _ in range(WARMUP_ITERATIONS):
            model(tensor)
        synchronize(device)
        times_ms = []
        output = None
        for _ in range(BENCHMARK_ITERATIONS):
            started = time.perf_counter()
            output = model(tensor)
            synchronize(device)
            times_ms.append((time.perf_counter() - started) * 1000.0)
    assert output is not None
    return output.detach().cpu().numpy().squeeze(), times_ms


def export_onnx(
    model: torch.nn.Module, path: Path, input_shape: tuple[int, ...]
) -> None:
    if not path.exists():
        dummy = torch.randn(*input_shape)
        torch.onnx.export(
            model.cpu(),
            dummy,
            path,
            input_names=["image"],
            output_names=["depth"],
            opset_version=18,
            do_constant_folding=True,
        )
    onnx.checker.check_model(onnx.load(path))


def benchmark_onnx(path: Path, input_array: np.ndarray) -> tuple[np.ndarray, list[float]]:
    session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    for _ in range(WARMUP_ITERATIONS):
        session.run(None, {input_name: input_array})
    times_ms = []
    output = None
    for _ in range(BENCHMARK_ITERATIONS):
        started = time.perf_counter()
        output = session.run(None, {input_name: input_array})[0]
        times_ms.append((time.perf_counter() - started) * 1000.0)
    assert output is not None
    return output.squeeze(), times_ms


def normalized(depth: np.ndarray) -> np.ndarray:
    low, high = np.percentile(depth, (2, 98))
    return np.clip((depth - low) / max(high - low, 1e-8), 0.0, 1.0)


def aligned_errors(reference: np.ndarray, candidate: np.ndarray) -> tuple[float, float]:
    matrix = np.stack([candidate.ravel(), np.ones(candidate.size)], axis=1)
    scale, shift = np.linalg.lstsq(matrix, reference.ravel(), rcond=None)[0]
    aligned = candidate * scale + shift
    difference = aligned - reference
    return float(np.mean(np.abs(difference))), float(np.sqrt(np.mean(difference**2)))


def print_stats(label: str, times_ms: list[float]) -> None:
    print(
        f"{label:24s} mean={statistics.mean(times_ms):8.2f} ms  "
        f"median={statistics.median(times_ms):8.2f} ms  "
        f"min={min(times_ms):8.2f} ms  max={max(times_ms):8.2f} ms  "
        f"sd={statistics.stdev(times_ms):7.2f} ms"
    )


def save_comparison(image_rgb: np.ndarray, outputs: dict[str, np.ndarray]) -> None:
    figure, axes = plt.subplots(1, 4, figsize=(16, 4))
    axes[0].imshow(image_rgb)
    axes[0].set_title("Input")
    for axis, (label, depth) in zip(axes[1:], outputs.items()):
        axis.imshow(normalized(depth), cmap="magma")
        axis.set_title(label)
    for axis in axes:
        axis.axis("off")
    figure.tight_layout()
    figure.savefig(OUTPUT_DIR / "backend_comparison.png", dpi=150)
    plt.close(figure)


def save_qualitative(model: torch.nn.Module, device: torch.device) -> None:
    figure, axes = plt.subplots(len(IMAGES), 2, figsize=(10, 11))
    for row, image_path in enumerate(IMAGES):
        image_rgb, input_array = prepare_image(image_path)
        with torch.inference_mode():
            depth = model(torch.from_numpy(input_array).to(device))
            synchronize(device)
        axes[row, 0].imshow(image_rgb)
        axes[row, 0].set_title(image_path.stem)
        axes[row, 1].imshow(normalized(depth.cpu().numpy().squeeze()), cmap="magma")
        axes[row, 1].set_title("ZipDepth inverse depth")
        for axis in axes[row]:
            axis.axis("off")
    figure.tight_layout()
    figure.savefig(OUTPUT_DIR / "qualitative_results.png", dpi=150)
    plt.close(figure)


def main() -> int:
    for path in IMAGES:
        if not path.exists():
            raise FileNotFoundError(f"Missing shared asset: {path}")
    if not torch.backends.mps.is_available():
        raise RuntimeError("MPS is not available")
    OUTPUT_DIR.mkdir(exist_ok=True)
    standard_checkpoint = ensure_checkpoint("standard")
    npu_checkpoint = ensure_checkpoint("npu")
    image_rgb, input_array = prepare_image(IMAGES[0])

    print(f"PyTorch: {torch.__version__}")
    print(f"ONNX Runtime: {ort.__version__}")
    input_height, input_width = input_array.shape[2:]
    print(f"Input: {IMAGES[0].name} -> {input_width}x{input_height}")
    print(f"Warmup: {WARMUP_ITERATIONS}, measured iterations: {BENCHMARK_ITERATIONS}\n")

    cpu = torch.device("cpu")
    mps = torch.device("mps")
    cpu_model = load_model(standard_checkpoint, cpu, npu=False)
    cpu_output, cpu_times = benchmark_torch(cpu_model, input_array, cpu)
    del cpu_model

    mps_model = load_model(standard_checkpoint, mps, npu=False)
    mps_output, mps_times = benchmark_torch(mps_model, input_array, mps)

    npu_model = load_model(npu_checkpoint, cpu, npu=True)
    onnx_path = LAB_DIR / f"zipdepth_base_npu_{input_width}x{input_height}.onnx"
    export_onnx(npu_model, onnx_path, input_array.shape)
    npu_cpu_output, npu_cpu_times = benchmark_torch(npu_model, input_array, cpu)
    del npu_model
    onnx_output, onnx_times = benchmark_onnx(onnx_path, input_array)

    print("--- Inference benchmark ---")
    print_stats("PyTorch CPU (standard)", cpu_times)
    print_stats("PyTorch MPS (standard)", mps_times)
    print_stats("PyTorch CPU (NPU)", npu_cpu_times)
    print_stats("ONNX Runtime CPU (NPU)", onnx_times)

    print("\n--- Output agreement after least-squares scale/shift alignment ---")
    for label, reference, candidate in [
        ("standard CPU vs MPS", cpu_output, mps_output),
        ("NPU PyTorch vs ONNX", npu_cpu_output, onnx_output),
        ("standard vs NPU", cpu_output, npu_cpu_output),
    ]:
        mae, rmse = aligned_errors(reference, candidate)
        print(f"{label:24s} MAE={mae:.8f} RMSE={rmse:.8f}")

    save_comparison(
        image_rgb,
        {
            "PyTorch CPU": cpu_output,
            "PyTorch MPS": mps_output,
            "ONNX Runtime CPU": onnx_output,
        },
    )
    save_qualitative(mps_model, mps)
    print(f"\nSaved results to {OUTPUT_DIR}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
