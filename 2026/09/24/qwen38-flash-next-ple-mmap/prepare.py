"""Build a view of the full 4-bit checkpoint whose PLE table is memory-mapped.

Uses mlx-vlm's own ``prepare_external_ple_model``: non-PLE weight files are
hard-linked (no payload copy), and ``ple-store.json`` indexes the PLE byte
ranges inside the original safetensors files.
"""

from __future__ import annotations

import json
from pathlib import Path

from huggingface_hub import snapshot_download
from mlx_vlm.models.qwen4_exp.ple_storage import prepare_external_ple_model

from eval import MODELS, PREPARED

SOURCE = MODELS["full4bit"]


def main() -> None:
    source = snapshot_download(SOURCE["repo"], revision=SOURCE["revision"])
    if PREPARED.exists() and any(PREPARED.iterdir()):
        print(f"already prepared: {PREPARED.relative_to(Path.cwd())}")
        return
    provenance = prepare_external_ple_model(source, PREPARED)
    manifest = json.loads((PREPARED / "ple-store.json").read_text())
    index = json.loads((PREPARED / "model.safetensors.index.json").read_text())
    print(
        f"linked {len(provenance['linked_weight_files'])} weight files; "
        f"PLE rows={manifest['row_count']:,} width={manifest['row_width']} "
        f"external_ple_bytes={int(index['metadata']['external_ple_bytes']) / 1e9:.1f} GB"
    )


if __name__ == "__main__":
    main()
