"""CosyVoice 3 zero-shot worker: one JSON request per line on stdin, one JSON reply per line on $WORKER_REPLY_FD."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import sys
import tarfile
import tempfile
import time
import traceback
import urllib.request
from pathlib import Path

LAB_DIR = Path(__file__).resolve().parents[2]
COSYVOICE_REVISION = "074ca6dc9e80a2f424f1f74b48bdd7d3fea531cc"
COSYVOICE_ARCHIVE_SHA256 = "10c587f0853db27667a64a0a2dc0788b1c782cdab223682691db78702082a550"
MATCHA_REVISION = "dd9105b34bf2be2230f4aa1e4769fb586a3c824e"  # submodule pinned by CosyVoice
MATCHA_ARCHIVE_SHA256 = "59c43afae79110e4057eaa43f45b5558b556435da8fc85eab83f0c819ba3358d"
MODEL_REPO = "FunAudioLLM/Fun-CosyVoice3-0.5B-2512"
MODEL_REVISION = "29e01c4e8d000f4bcd70751be16fa94bf3d85a18"
# Files only for the RL model, TensorRT, batched tokenization and the demo audio.
MODEL_IGNORE = ["llm.rl.pt", "*.batch.onnx", "flow.decoder.estimator.fp32.onnx", "asset/*"]
# Upstream uses this system prompt for CosyVoice 3 (example.py).
SYSTEM_PROMPT = "You are a helpful assistant.<|endofprompt|>"

replies = os.fdopen(int(os.environ["WORKER_REPLY_FD"]), "w", buffering=1)
sys.stdout = sys.stderr


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch_source(url: str, expected: str, prefix: str, destination: Path) -> None:
    if destination.exists():
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=destination.parent) as directory:
        archive = Path(directory) / "source.tar.gz"
        print(f"[download] {url}")
        urllib.request.urlretrieve(url, archive)
        actual = sha256(archive)
        if expected == "PENDING":
            print(f"[sha256] {url}: {actual}")
        elif actual != expected:
            raise RuntimeError(f"sha256 mismatch for {url}: {actual}")
        base = Path(directory).resolve()
        with tarfile.open(archive, "r:gz") as tar:
            for member in tar.getmembers():
                resolved = (Path(directory) / member.name).resolve()
                if base not in resolved.parents and resolved != base:
                    raise ValueError(f"unsafe archive member: {member.name}")
            tar.extractall(directory)
        shutil.move(str(Path(directory) / prefix), destination)


def ensure_assets() -> tuple[Path, Path]:
    source = LAB_DIR / "vendor/CosyVoice"
    fetch_source(
        f"https://github.com/FunAudioLLM/CosyVoice/archive/{COSYVOICE_REVISION}.tar.gz",
        COSYVOICE_ARCHIVE_SHA256,
        f"CosyVoice-{COSYVOICE_REVISION}",
        source,
    )
    matcha = source / "third_party/Matcha-TTS"
    if not (matcha / "matcha").exists():
        shutil.rmtree(matcha, ignore_errors=True)
        fetch_source(
            f"https://github.com/shivammehta25/Matcha-TTS/archive/{MATCHA_REVISION}.tar.gz",
            MATCHA_ARCHIVE_SHA256,
            f"Matcha-TTS-{MATCHA_REVISION}",
            matcha,
        )
    from huggingface_hub import snapshot_download

    model_dir = Path(
        snapshot_download(
            MODEL_REPO,
            revision=MODEL_REVISION,
            local_dir=LAB_DIR / "models" / MODEL_REPO.split("/")[-1],
            ignore_patterns=MODEL_IGNORE,
        )
    )
    return source, model_dir


source_dir, model_dir = ensure_assets()
sys.path[:0] = [str(source_dir), str(source_dir / "third_party/Matcha-TTS")]

import soundfile as sf  # noqa: E402
import torch  # noqa: E402
from cosyvoice.cli.cosyvoice import AutoModel  # noqa: E402

# Upstream selects CUDA or CPU. MPS was not usable without patching (HiFT keeps float64 tensors).
cosyvoice = None


def synthesize(request: dict) -> dict:
    global cosyvoice
    timings = {}
    started = time.perf_counter()
    if cosyvoice is None:
        cosyvoice = AutoModel(model_dir=str(model_dir))
    timings["load"] = time.perf_counter() - started

    text = request["text"]
    reference_text = request.get("reference_text") or ""
    torch.manual_seed(int(request.get("seed", 0)))
    started = time.perf_counter()
    if reference_text:
        mode = "zero-shot"
        outputs = cosyvoice.inference_zero_shot(
            text, SYSTEM_PROMPT + reference_text, request["reference_wav"], stream=False
        )
    else:
        # Without a transcript, upstream's cross-lingual mode uses only the reference audio.
        mode = "cross-lingual (no transcript)"
        outputs = cosyvoice.inference_cross_lingual(SYSTEM_PROMPT + text, request["reference_wav"], stream=False)
    audio = torch.cat([output["tts_speech"] for output in outputs], dim=1).squeeze().cpu().numpy()
    timings["generate"] = time.perf_counter() - started
    sf.write(request["output_wav"], audio, cosyvoice.sample_rate)
    return {
        "engine": "cosyvoice3",
        "model": "Fun-CosyVoice3-0.5B-2512",
        "device": "cpu float32",
        "input_text": text,
        "mode": mode,
        "sample_rate": cosyvoice.sample_rate,
        "seconds": len(audio) / cosyvoice.sample_rate,
        "timings": timings,
    }


def main() -> None:
    global cosyvoice
    cosyvoice = AutoModel(model_dir=str(model_dir))
    replies.write(json.dumps({"ready": True}) + "\n")
    for line in sys.stdin:
        request = json.loads(line)
        try:
            reply = {"id": request.get("id"), "ok": True, **synthesize(request)}
        except Exception as error:
            traceback.print_exc()
            reply = {"id": request.get("id"), "ok": False, "error": f"{type(error).__name__}: {error}"}
        replies.write(json.dumps(reply, ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()
