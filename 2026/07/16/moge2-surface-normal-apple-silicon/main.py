from __future__ import annotations

import hashlib
import json
import platform
import statistics
import time
from pathlib import Path

import cv2
import matplotlib.pyplot as plt
import numpy as np
import torch
from huggingface_hub import hf_hub_download
from moge.model.v2 import MoGeModel


LAB_DIR = Path(__file__).resolve().parent
REPO_ROOT = LAB_DIR.parents[3]
OUTPUT_DIR = LAB_DIR / "output"
MODEL_REPO = "Ruicheng/moge-2-vits-normal"
MODEL_REVISION = "679230677b4d282c6f304189a93e98e14f085902"
MODEL_PATH = LAB_DIR / "model.pt"
MODEL_SHA256 = "79a16621928c2bf0ed04659218c55c01075e950507f40bb3332fb4c873d3e1dc"
SHORT_SIDE = 384
RESOLUTION_LEVEL = 5
WARMUPS = 3
RUNS = 10
IMAGES = {
    "street": REPO_ROOT / "tests/assets/jpg/street_scene_1774x887_287kb.jpg",
    "objects": REPO_ROOT / "tests/assets/jpg/objects_1536x1024_358kb.jpg",
    "crowd": REPO_ROOT / "tests/assets/jpg/many_face_1280x720_275kb.jpg",
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_model() -> None:
    if not MODEL_PATH.exists():
        cached = Path(
            hf_hub_download(
                repo_id=MODEL_REPO,
                filename="model.pt",
                revision=MODEL_REVISION,
            )
        )
        MODEL_PATH.write_bytes(cached.read_bytes())
    actual_sha256 = sha256(MODEL_PATH)
    if actual_sha256 != MODEL_SHA256:
        raise RuntimeError(
            f"model SHA-256 mismatch: expected {MODEL_SHA256}, got {actual_sha256}"
        )


def load_image(path: Path) -> tuple[np.ndarray, torch.Tensor]:
    bgr = cv2.imread(str(path), cv2.IMREAD_COLOR)
    if bgr is None:
        raise FileNotFoundError(path)
    rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
    height, width = rgb.shape[:2]
    scale = SHORT_SIDE / min(height, width)
    resized = cv2.resize(
        rgb,
        (round(width * scale), round(height * scale)),
        interpolation=cv2.INTER_AREA,
    )
    tensor = torch.from_numpy(resized.copy()).permute(2, 0, 1).float() / 255.0
    return resized, tensor


def synchronize(device: torch.device) -> None:
    if device.type == "mps":
        torch.mps.synchronize()


def infer(model: MoGeModel, image: torch.Tensor) -> dict[str, torch.Tensor]:
    return model.infer(
        image,
        resolution_level=RESOLUTION_LEVEL,
        use_fp16=False,
        apply_mask=True,
    )


def benchmark(
    model: MoGeModel, image: torch.Tensor, device: torch.device
) -> tuple[dict[str, float], dict[str, torch.Tensor]]:
    model = model.to(device).eval()
    image = image.to(device)
    for _ in range(WARMUPS):
        output = infer(model, image)
        synchronize(device)

    timings = []
    for _ in range(RUNS):
        synchronize(device)
        start = time.perf_counter()
        output = infer(model, image)
        synchronize(device)
        timings.append((time.perf_counter() - start) * 1000)

    result = {key: value.detach().cpu() for key, value in output.items()}
    metrics = {
        "mean_ms": statistics.mean(timings),
        "median_ms": statistics.median(timings),
        "min_ms": min(timings),
        "max_ms": max(timings),
        "std_ms": statistics.pstdev(timings),
    }
    return metrics, result


def normal_to_rgb(normal: np.ndarray, mask: np.ndarray) -> np.ndarray:
    rgb = np.clip((normal + 1.0) / 2.0, 0.0, 1.0)
    return np.where(mask[..., None], rgb, 0.0)


def point_map_to_normal(points: np.ndarray, mask: np.ndarray) -> np.ndarray:
    finite_points = np.where(mask[..., None] & np.isfinite(points), points, np.nan)
    fill = np.nanmedian(finite_points.reshape(-1, 3), axis=0)
    points = np.where(np.isfinite(finite_points), finite_points, fill)
    tangent_y = np.gradient(points, axis=0)
    tangent_x = np.gradient(points, axis=1)
    # OpenCV camera coordinates use x-right, y-down, z-forward. The cross product
    # points away from the camera, so negate it to match MoGe's camera-facing normals.
    normal = -np.cross(tangent_x, tangent_y)
    normal /= np.maximum(np.linalg.norm(normal, axis=-1, keepdims=True), 1e-8)
    return np.where(mask[..., None], normal, 0.0)


def angular_error(a: np.ndarray, b: np.ndarray, mask: np.ndarray) -> np.ndarray:
    cosine = np.sum(a * b, axis=-1)
    error = np.degrees(np.arccos(np.clip(cosine, -1.0, 1.0)))
    return np.where(mask, error, np.nan)


def save_qualitative(
    inputs: dict[str, np.ndarray], outputs: dict[str, dict[str, torch.Tensor]]
) -> dict[str, dict[str, float]]:
    figure, axes = plt.subplots(len(inputs), 4, figsize=(16, 10))
    summaries: dict[str, dict[str, float]] = {}
    for row, name in enumerate(inputs):
        output = outputs[name]
        normal = output["normal"].numpy()
        points = output["points"].numpy()
        mask = output["mask"].numpy().astype(bool)
        derived = point_map_to_normal(points, mask)
        error = angular_error(normal, derived, mask)
        valid_error = error[np.isfinite(error)]
        summaries[name] = {
            "valid_pixels_percent": float(mask.mean() * 100),
            "angular_mean_deg": float(valid_error.mean()),
            "angular_median_deg": float(np.median(valid_error)),
            "angular_p90_deg": float(np.percentile(valid_error, 90)),
        }

        panels = [
            (inputs[name], "input", None),
            (normal_to_rgb(normal, mask), "predicted normal", None),
            (normal_to_rgb(derived, mask), "normal from point map", None),
            (error, "angular difference", "magma"),
        ]
        for column, (image, title, cmap) in enumerate(panels):
            axes[row, column].imshow(image, cmap=cmap, vmin=0 if cmap else None, vmax=90 if cmap else None)
            axes[row, column].set_title(f"{name}: {title}")
            axes[row, column].axis("off")
    figure.tight_layout()
    figure.savefig(OUTPUT_DIR / "qualitative_results.png", dpi=150)
    plt.close(figure)
    return summaries


def main() -> None:
    OUTPUT_DIR.mkdir(exist_ok=True)
    download_model()
    inputs = {name: load_image(path) for name, path in IMAGES.items()}
    model = MoGeModel.from_pretrained(MODEL_PATH)

    cpu_metrics, cpu_street = benchmark(model, inputs["street"][1], torch.device("cpu"))
    if not torch.backends.mps.is_available():
        raise RuntimeError("PyTorch MPS is unavailable")
    mps_metrics, mps_street = benchmark(model, inputs["street"][1], torch.device("mps"))

    qualitative: dict[str, dict[str, torch.Tensor]] = {"street": mps_street}
    model = model.to("mps")
    for name in ("objects", "crowd"):
        qualitative[name] = {
            key: value.detach().cpu()
            for key, value in infer(model, inputs[name][1].to("mps")).items()
        }
        synchronize(torch.device("mps"))

    cpu_normal = cpu_street["normal"].numpy()
    mps_normal = mps_street["normal"].numpy()
    valid = cpu_street["mask"].numpy().astype(bool) & mps_street["mask"].numpy().astype(bool)
    backend_error = angular_error(cpu_normal, mps_normal, valid)
    backend_valid = backend_error[np.isfinite(backend_error)]

    report = {
        "model": {
            "repo": MODEL_REPO,
            "revision": MODEL_REVISION,
            "size_bytes": MODEL_PATH.stat().st_size,
            "sha256": sha256(MODEL_PATH),
            "parameters": sum(parameter.numel() for parameter in model.parameters()),
        },
        "conditions": {
            "short_side": SHORT_SIDE,
            "resolution_level": RESOLUTION_LEVEL,
            "warmups": WARMUPS,
            "runs": RUNS,
            "input_shapes": {
                name: list(tensor.shape) for name, (_, tensor) in inputs.items()
            },
        },
        "benchmark": {"cpu": cpu_metrics, "mps": mps_metrics},
        "backend_normal_difference_deg": {
            "mean": float(backend_valid.mean()),
            "median": float(np.median(backend_valid)),
            "max": float(backend_valid.max()),
        },
        "qualitative_metrics": save_qualitative(
            {name: image for name, (image, _) in inputs.items()}, qualitative
        ),
        "environment": {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "torch": torch.__version__,
            "mps_available": torch.backends.mps.is_available(),
        },
    }
    (OUTPUT_DIR / "results.json").write_text(
        json.dumps(report, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
