#!/usr/bin/env python3
"""Compare the converted audio that the app uploaded (on-device parity run:
Kyoko fixture, fixture noise, 3 steps) with the Python ONNX Runtime output and
the upstream PyTorch streaming output for the same noise (parity.py writes it
to build/listen/kyoko_s3_torch.wav)."""
import json
import sys
from pathlib import Path

import numpy as np
import soundfile as sf

from parity import compare_wav

LAB = Path(__file__).resolve().parents[1]


def main():
    torch_ref, _ = sf.read(LAB / "build/listen/kyoko_s3_torch.wav", dtype="float32")
    rows = []
    for path in sorted((LAB / "build/device").glob("*-parity_*.f32")):
        got = np.fromfile(path, "<f4")
        variant = path.stem.split("parity_")[1]
        expected = np.fromfile(LAB / f"build/serve/fixtures/expected_{variant}_s3.f32", "<f4")
        row = {"file": path.name, "variant": variant, "vsPythonOnnx": compare_wav(got, expected),
               "vsUpstreamTorch": compare_wav(got, torch_ref)}
        rows.append(row)
        sf.write(LAB / "build/listen" / f"kyoko_s3_device_{path.stem}.wav", got, 16000, subtype="FLOAT")
        print(row["file"], {k: (round(v["snrDb"], 1), round(v["lsdDb"], 2)) for k, v in row.items() if isinstance(v, dict)})
    out = LAB / "results/device-parity.json"
    out.write_text(json.dumps(rows, indent=2) + "\n")


if __name__ == "__main__":
    main()
