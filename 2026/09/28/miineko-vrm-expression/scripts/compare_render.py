"""Compare neutral renders with the original, using fixed screen regions."""

import json
from pathlib import Path

import numpy as np
from PIL import Image


root = Path(__file__).resolve().parents[1]
artifacts = root / "artifacts"
original = np.asarray(
    Image.open(artifacts / "mask-probe-original.png").convert("RGB"), dtype=np.int16
)
regions = {
    "face": [180, 120, 720, 550],
    "face_core": [255, 300, 640, 505],
    "body_control": [180, 550, 720, 830],
}
result = {
    "method": {
        "imageSize": [900, 900],
        "render": "Blender 5.1.2 Cycles, 32 samples, fixed camera and lighting",
        "meanAbsoluteError": "mean absolute difference per RGB channel, 0-255",
        "changedPixelFraction": "fraction with at least one RGB channel difference > 12",
        "regionsXYXY": regions,
    },
    "comparisons": {},
}
for filename in (
    "mask-probe-neutral.png",
    "mask-probe-baked.png",
    "prosthetic-neutral.png",
):
    image = np.asarray(Image.open(artifacts / filename).convert("RGB"), dtype=np.int16)
    if image.shape != original.shape:
        raise ValueError(f"Unexpected render size: {filename}: {image.shape}")
    measured = {}
    for name, (x0, y0, x1, y1) in regions.items():
        diff = np.abs(original[y0:y1, x0:x1] - image[y0:y1, x0:x1])
        measured[name] = {
            "meanAbsoluteError": round(float(diff.mean()), 4),
            "changedPixelFraction": round(float(np.any(diff > 12, axis=2).mean()), 6),
        }
    result["comparisons"][filename] = measured

destination = root / "results" / "mask-render-comparison.json"
destination.write_text(json.dumps(result, indent=2) + "\n")
print(destination)
