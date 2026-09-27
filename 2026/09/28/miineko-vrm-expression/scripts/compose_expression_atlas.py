"""Compose one BaseColor atlas: original model plus aligned mask states."""

import os
from pathlib import Path

from PIL import Image


root = Path(__file__).resolve().parents[1]
out = root / "artifacts"
source_path = os.environ.get("MIINEKO_BASECOLOR")
if not source_path:
    raise RuntimeError("Set MIINEKO_BASECOLOR to the original Tripo BaseColor image")
original = Image.open(source_path).convert("RGB")
neutral = Image.open(out / "face-local-neutral.png").convert("RGB")
blink = Image.open(out / "face-local-blink.png").convert("RGB")
if original.size != (4096, 4096):
    raise RuntimeError(f"Unexpected original size: {original.size}")
atlas = Image.new("RGB", (8192, 4096), (0, 0, 0))
atlas.paste(original, (0, 0))
atlas.paste(neutral.resize((2048, 2048), Image.Resampling.LANCZOS), (4096, 0))
atlas.paste(blink.resize((2048, 2048), Image.Resampling.LANCZOS), (6144, 0))
destination = out / "miineko-expression-atlas.png"
atlas.save(destination)
print(destination)
