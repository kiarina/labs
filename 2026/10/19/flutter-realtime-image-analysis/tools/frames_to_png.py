"""Writes work/frames/*.rgb as lossless PNG into a directory (the app's assets)."""

import json
import sys
from pathlib import Path

import cv2
import numpy as np

LAB = Path(__file__).resolve().parent.parent
out = Path(sys.argv[1])
out.mkdir(parents=True, exist_ok=True)
for f in json.loads((LAB / "fixtures/frames.json").read_text()):
    rgb = np.frombuffer((LAB / f"work/frames/{f['name']}.rgb").read_bytes(), np.uint8).reshape(f["height"], f["width"], 3)
    cv2.imwrite(str(out / f"{f['name']}.png"), np.ascontiguousarray(rgb[..., ::-1]), [cv2.IMWRITE_PNG_COMPRESSION, 6])
