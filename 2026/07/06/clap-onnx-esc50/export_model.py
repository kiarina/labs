from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

import onnx
import onnxruntime as ort
import torch
from transformers import ClapModel


MODEL_ID = "laion/clap-htsat-unfused"
MODEL_REVISION = "84bcbbd1d619e407a8216371ddef36e458d95d93"
MODEL_SHA256 = "b23099962830b1afa5398efbb6f5321ef8f63f8fcf93f5019837c47118a8a1c5"
FRAMES = 1001
MEL_BINS = 64
EMBEDDING_DIMENSION = 512


class ClapAudioEncoder(torch.nn.Module):
    def __init__(self, model: ClapModel) -> None:
        super().__init__()
        self.model = model

    def forward(
        self, input_features: torch.Tensor, is_longer: torch.Tensor
    ) -> torch.Tensor:
        embeddings = self.model.get_audio_features(
            input_features=input_features, is_longer=is_longer
        )
        return embeddings + is_longer.to(embeddings.dtype) * 0


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def export(destination: Path) -> None:
    print(f"download: {MODEL_ID}@{MODEL_REVISION}", flush=True)
    model = ClapModel.from_pretrained(MODEL_ID, revision=MODEL_REVISION)
    encoder = ClapAudioEncoder(model).eval()
    input_features = torch.zeros((1, 1, FRAMES, MEL_BINS), dtype=torch.float32)
    is_longer = torch.zeros((1, 1), dtype=torch.bool)
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    print(f"export: {destination}", flush=True)
    with torch.inference_mode():
        torch.onnx.export(
            encoder,
            (input_features, is_longer),
            temporary,
            input_names=["input_features", "is_longer"],
            output_names=["embeddings"],
            dynamic_axes={
                "input_features": {0: "batch_size"},
                "is_longer": {0: "batch_size"},
                "embeddings": {0: "batch_size"},
            },
            opset_version=18,
            dynamo=False,
        )
    temporary.replace(destination)


def verify(path: Path) -> None:
    onnx.checker.check_model(path)
    session = ort.InferenceSession(str(path), providers=["CPUExecutionProvider"])
    inputs = session.get_inputs()
    outputs = session.get_outputs()
    expected_inputs = [
        ("input_features", ["batch_size", 1, FRAMES, MEL_BINS], "tensor(float)"),
        ("is_longer", ["batch_size", 1], "tensor(bool)"),
    ]
    actual_inputs = [(item.name, item.shape, item.type) for item in inputs]
    expected_outputs = [
        ("embeddings", ["batch_size", EMBEDDING_DIMENSION], "tensor(float)")
    ]
    actual_outputs = [(item.name, item.shape, item.type) for item in outputs]
    if actual_inputs != expected_inputs:
        raise ValueError(f"unexpected model inputs: {actual_inputs}")
    if actual_outputs != expected_outputs:
        raise ValueError(f"unexpected model outputs: {actual_outputs}")
    actual_sha256 = sha256_file(path)
    if actual_sha256 != MODEL_SHA256:
        raise ValueError(
            f"model SHA-256 mismatch: expected {MODEL_SHA256}, got {actual_sha256}"
        )
    print(f"SHA-256: {actual_sha256}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path, nargs="?", default=Path("model.onnx"))
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()

    if not args.verify_only:
        export(args.destination)
    verify(args.destination)


if __name__ == "__main__":
    main()
