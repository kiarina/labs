from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
from pathlib import Path

from config import MAX_SEQUENCE_LENGTH, MODEL_ID, MODEL_REVISION, OUTPUT_DIR, PTE_PATHS


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def export_command(output: Path, quantized: bool) -> list[str]:
    command = [
        sys.executable,
        "-m",
        "executorch.backends.mlx.examples.llm.export_llm_hf",
        "--model-id",
        MODEL_ID,
        "--revision",
        MODEL_REVISION,
        "--output",
        str(output),
        "--max-seq-len",
        str(MAX_SEQUENCE_LENGTH),
        "--dtype",
        "bf16",
        "--use-custom-sdpa",
        "--use-custom-kv-cache",
    ]
    if quantized:
        command.extend(["--qlinear", "4w", "--qembedding", "4w"])
    return command


def export_one(name: str, path: Path, force: bool) -> dict[str, object]:
    quantized = name == "mlx_int4"
    if force or not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        started = time.perf_counter()
        subprocess.run(export_command(path, quantized), check=True)
        export_seconds = time.perf_counter() - started
        reused = False
    else:
        export_seconds = None
        reused = True

    return {
        "backend": name,
        "path": str(path.relative_to(path.parent.parent)),
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
        "export_seconds": export_seconds,
        "reused": reused,
        "dtype": "bf16",
        "linear_quantization": "4-bit affine, group size 32" if quantized else None,
        "embedding_quantization": "4-bit affine, group size 32" if quantized else None,
        "custom_sdpa": True,
        "custom_kv_cache": True,
    }


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args(argv)

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()
    models = [export_one(name, path, args.force) for name, path in PTE_PATHS.items()]
    report = {
        "model_id": MODEL_ID,
        "model_revision": MODEL_REVISION,
        "max_sequence_length_requested": MAX_SEQUENCE_LENGTH,
        "models": models,
        "wall_seconds": time.perf_counter() - started,
        "versions": {
            "python": sys.version.split()[0],
        },
    }
    output = OUTPUT_DIR / "export.json"
    output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
