"""Download pinned MeanVC2 assets and run file-based (non-streaming) conversion.

The conversion follows upstream `src/infer/infer_e2e.py` at the pinned revision:
Fast-U2++ bottleneck features from the source, a WavLM + ECAPA-TDNN speaker
embedding from the reference, the mean-flow DiT decoder, and the Vocos vocoder.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import sys
import tarfile
import tempfile
import time
import types
import urllib.request
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import torch

SAMPLE_RATE = 16_000

MEANVC2_REVISION = "13acf84c1bf135ea5edad9c245b345289b06b33e"
MEANVC2_ARCHIVE_SHA256 = "1c7dad50d5f23be924cecd73890c8992ef11bb6d538355cdd242a2e1849dea73"
MEANVC2_MODEL_REVISION = "39cdd19522fe896c227da691314d9a0e3b995486"
MEANVC2_FILES = {
    # Hugging Face filename -> (path inside the MeanVC2 source tree, sha256)
    "fastu2pp_80ms.pt": ("preprocess/ckpts/fastu2pp_80ms.pt", "4338739bd13e0f7718276373e9547ce1f9aa02ec0867452860df9e837f90e4d2"),
    "fastu2pp_160ms.pt": ("preprocess/ckpts/fastu2pp_160ms.pt", "9a372c1b7178f564a15da1cd36901d7d0c9081a2fabf53cb6cc0d971deca4928"),
    "meanvc2_120ms_40ms.safetensors": (
        "ckpts/pretrained_models/meanvc2_120ms_40ms.safetensors",
        "04ea21a4fb55400469e6004ae842c3e7f059f759e92946fb95123418cad5d818",
    ),
    "meanvc2_40ms_40ms.safetensors": (
        "ckpts/pretrained_models/meanvc2_40ms_40ms.safetensors",
        "01caafec9a3991a5514df9412952d24ae3370406358a01e20e03df41f2f5d515",
    ),
    "vocos.pt": ("ckpts/vocos/vocos.pt", "df1f2ba9f7ac35c96832579421ee1ed913a68c3a1d2f8a6536739f902f194a93"),
}
# ECAPA-TDNN weights fine-tuned on WavLM-Large, shared through Google Drive
# by the MeanVC authors (upstream `initialization.py` links the same id).
SPEAKER_GOOGLE_DRIVE_ID = "1-aE1NfzpRCLxA4GUxX9ITI3F9LlbtEGP"
SPEAKER_SHA256 = "51f07e3b94d9e0262a6a675ef5a087be3dd09e8c62e9d886827f44f82fe7f94b"
# Upstream downloads WavLM-Large from a mutable release URL and imports s3prl
# from the installed package. Both are pinned here instead.
S3PRL_REVISION = "ec8064b5889f81ca460fbe2c094ce576a6f120b7"
S3PRL_ARCHIVE_SHA256 = "fa182b81c0963d82aa4bd2e567bdfb42ecabebe2ac6bee92e4acc08233b70dbe"
WAVLM_MODEL_REVISION = "8cad0b370e7e35f8d56951d95d2be036ea85510c"
WAVLM_SHA256 = "6fb4b3c3e6aa567f0a997b30855859cb81528ee8078802af439f7b2da0bf100f"

# Same presets as upstream `infer_e2e.py`.
MODEL_PRESETS = {
    "120ms": {
        "asr_ckpt": "preprocess/ckpts/fastu2pp_160ms.pt",
        "bn_window": 19,
        "bn_stride": 16,
        "offset_init": 8,
        "offset_step": 4,
        "req_cache": 8,
        "vc_ckpt": "ckpts/pretrained_models/meanvc2_120ms_40ms.safetensors",
        "vc_config": "src/config/config_120ms_40ms.json",
        "chunk_size": 12,
        "block_size": 4,
    },
    "40ms": {
        "asr_ckpt": "preprocess/ckpts/fastu2pp_80ms.pt",
        "bn_window": 11,
        "bn_stride": 8,
        "offset_init": 4,
        "offset_step": 2,
        "req_cache": 4,
        "vc_ckpt": "ckpts/pretrained_models/meanvc2_40ms_40ms.safetensors",
        "vc_config": "src/config/config_40ms_40ms.json",
        "chunk_size": 4,
        "block_size": 4,
    },
}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def verify(path: Path, expected: str) -> None:
    actual = sha256(path)
    if expected == "PENDING":
        print(f"  [sha256] {path.name}: {actual}")
        return
    if actual != expected:
        raise RuntimeError(f"sha256 mismatch for {path}: {actual} != {expected}")


def download(url: str, path: Path, expected: str) -> None:
    if path.exists():
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    print(f"  [download] {url}")
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        urllib.request.urlretrieve(url, temporary_path)
        verify(temporary_path, expected)
        temporary_path.replace(path)
    finally:
        temporary_path.unlink(missing_ok=True)


def extract_archive(archive: Path, prefix: str, destination: Path) -> None:
    with tempfile.TemporaryDirectory(dir=destination.parent) as temporary_dir:
        temporary_path = Path(temporary_dir)
        base = temporary_path.resolve()
        with tarfile.open(archive, "r:gz") as tar:
            for member in tar.getmembers():
                resolved = (temporary_path / member.name).resolve()
                if base not in resolved.parents and resolved != base:
                    raise ValueError(f"unsafe archive member: {member.name}")
            tar.extractall(temporary_path)
        shutil.move(str(temporary_path / prefix), destination)


def ensure_assets(lab_dir: Path) -> tuple[Path, Path]:
    vendor_dir = lab_dir / "vendor"
    vendor_dir.mkdir(parents=True, exist_ok=True)

    source_dir = vendor_dir / "MeanVC2"
    if not (source_dir / "src/infer/infer_e2e.py").exists():
        archive = vendor_dir / f"MeanVC2-{MEANVC2_REVISION}.tar.gz"
        download(
            f"https://github.com/ASLP-lab/MeanVC2/archive/{MEANVC2_REVISION}.tar.gz",
            archive,
            MEANVC2_ARCHIVE_SHA256,
        )
        extract_archive(archive, f"MeanVC2-{MEANVC2_REVISION}", source_dir)

    s3prl_dir = vendor_dir / "s3prl"
    if not (s3prl_dir / "s3prl/upstream/wavlm/expert.py").exists():
        archive = vendor_dir / f"s3prl-{S3PRL_REVISION}.tar.gz"
        download(
            f"https://github.com/s3prl/s3prl/archive/{S3PRL_REVISION}.tar.gz",
            archive,
            S3PRL_ARCHIVE_SHA256,
        )
        extract_archive(archive, f"s3prl-{S3PRL_REVISION}", s3prl_dir)

    for filename, (relative, digest) in MEANVC2_FILES.items():
        download(
            "https://huggingface.co/ASLP-lab/MeanVC2/resolve/"
            f"{MEANVC2_MODEL_REVISION}/{filename}",
            source_dir / relative,
            digest,
        )

    download(
        "https://huggingface.co/s3prl/converted_ckpts/resolve/"
        f"{WAVLM_MODEL_REVISION}/wavlm_large.pt",
        source_dir / "preprocess/ckpts/wavlm_large.pt",
        WAVLM_SHA256,
    )

    speaker_path = source_dir / "preprocess/ckpts/wavlm_large_finetune.pth"
    if not speaker_path.exists():
        import gdown

        temporary = speaker_path.with_suffix(".download")
        gdown.download(id=SPEAKER_GOOGLE_DRIVE_ID, output=str(temporary), quiet=False)
        verify(temporary, SPEAKER_SHA256)
        temporary.replace(speaker_path)

    return source_dir, s3prl_dir


def import_upstream(source_dir: Path, s3prl_dir: Path):
    """Import the inference modules without running `src/model/__init__.py`.

    That `__init__` imports the trainer (accelerate, wandb, ema-pytorch), which
    inference does not need, so the packages are registered as bare namespaces.
    """
    for path in (s3prl_dir, source_dir / "src/infer", source_dir):
        if str(path) not in sys.path:
            sys.path.insert(0, str(path))
    for name, relative in (("src", "src"), ("src.model", "src/model")):
        if name not in sys.modules:
            package = types.ModuleType(name)
            package.__path__ = [str(source_dir / relative)]
            sys.modules[name] = package
    import dit_kvcache
    import infer_e2e
    from preprocess.models.ecapa_tdnn import ECAPA_TDNN_SMALL

    return dit_kvcache.DiT, infer_e2e, ECAPA_TDNN_SMALL


def load_vc_weights(model: torch.nn.Module, path: Path) -> torch.nn.Module:
    """Same as upstream `load_checkpoint(..., use_ema=True)` for safetensors."""
    from safetensors.torch import load_file

    state = {
        key.replace("ema_model.", ""): value
        for key, value in load_file(str(path)).items()
        if key not in ("initted", "step")
    }
    model.load_state_dict(state, strict=False)
    return model


@dataclass
class Conversion:
    audio: np.ndarray
    bn_seconds: float
    vc_seconds: float


class MeanVC2:
    def __init__(self, lab_dir: Path, threads: int = 4) -> None:
        self.source_dir, s3prl_dir = ensure_assets(lab_dir)
        torch.set_num_threads(threads)
        self.DiT, self.e2e, ecapa_class = import_upstream(self.source_dir, s3prl_dir)

        started = time.perf_counter()
        speaker = ecapa_class(feat_dim=1024, feat_type="wavlm_large")
        state = torch.load(
            self.source_dir / "preprocess/ckpts/wavlm_large_finetune.pth",
            map_location="cpu",
        )
        speaker.load_state_dict(state["model"], strict=False)
        self.speaker = speaker.eval()
        self.vocos = torch.jit.load(str(self.source_dir / "ckpts/vocos/vocos.pt"))
        self.models: dict[str, tuple[torch.jit.ScriptModule, torch.nn.Module]] = {}
        self.load_seconds = time.perf_counter() - started

    def _model(self, name: str):
        if name not in self.models:
            preset = MODEL_PRESETS[name]
            asr = torch.jit.load(str(self.source_dir / preset["asr_ckpt"]), map_location="cpu")
            config = json.loads((self.source_dir / preset["vc_config"]).read_text())
            vc = self.DiT(**config["model"])
            vc = load_vc_weights(vc, self.source_dir / preset["vc_ckpt"]).float().eval()
            self.models[name] = (asr.eval(), vc)
        return self.models[name]

    @torch.inference_mode()
    def speaker_embedding(self, audio: np.ndarray) -> np.ndarray:
        tensor = torch.from_numpy(audio.astype(np.float32)).unsqueeze(0)
        return self.speaker(tensor).squeeze().cpu().numpy()

    def convert(
        self,
        source: np.ndarray,
        embedding: np.ndarray,
        model: str = "120ms",
        steps: int = 3,
        seed: int = 0,
    ) -> Conversion:
        preset = MODEL_PRESETS[model]
        asr, vc = self._model(model)
        # Upstream reads int16 wav files; write the float source the same way.
        with tempfile.NamedTemporaryFile(suffix=".wav") as file:
            import soundfile as sf

            sf.write(file.name, np.clip(source, -1, 1), SAMPLE_RATE, subtype="PCM_16")
            started = time.perf_counter()
            bn = self.e2e.extract_bn(
                file.name,
                asr,
                window=preset["bn_window"],
                stride=preset["bn_stride"],
                offset_init=preset["offset_init"],
                offset_step=preset["offset_step"],
                req_cache=preset["req_cache"],
            )
        bn_seconds = time.perf_counter() - started

        torch.manual_seed(seed)
        started = time.perf_counter()
        _, wav = self.e2e.vc_inference(
            vc,
            self.vocos,
            bn,
            embedding,
            preset["chunk_size"],
            preset["block_size"],
            steps,
            "cpu",
        )
        vc_seconds = time.perf_counter() - started
        return Conversion(wav.squeeze().cpu().numpy(), bn_seconds, vc_seconds)
