from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import math
import os
import platform
import resource
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import types
import urllib.request
from dataclasses import dataclass
from itertools import combinations
from pathlib import Path

import gdown
import numpy as np
import onnxruntime as ort
import soundfile as sf
import torch


SAMPLE_RATE = 16_000
SEED = 20_260_719
TRIALS = 3
INFERENCE_STEPS = 2
STEADY_CHUNK_SAMPLES = 3_200
FIRST_CHUNK_SAMPLES = 3_920
ECAPA_DIMENSION = 192

SOURCE_SEGMENTS = ((0.000, 1.851), (4.737, 7.317), (9.677, 11.834))
TARGET_SEGMENTS = ((1.851, 4.737), (7.317, 9.677), (11.834, 14.171))

MEANVC_REVISION = "b07024579284975bc8a6a9aa72201d6279b417ab"
MEANVC_ARCHIVE_SHA256 = (
    "db61408519c83c597389f5c1577d0747de4429cfd04beb45cc281d65c765b3b0"
)
MEANVC_MODEL_REVISION = "2e2a116d1b1fdd0957c730be5cef3cd2ddf16779"
MEANVC_FILES = {
    "fastu2++.pt": "4d6bc4290c4d489ed50b6ffbbcda33bd3ba9551506852c7f2fa683f9fe9512a1",
    "meanvc_200ms.pt": "17a234944c7e63bfc94e71eea7de8dfb9f7f2e990cde9fd8df12ddad5237c68f",
    "vocos.pt": "9e8aba28aa9cea0813e571a25ee33ef35bd74c803da34a65e683d9b0f7e2f281",
}
WAVLM_GOOGLE_DRIVE_ID = "1-aE1NfzpRCLxA4GUxX9ITI3F9LlbtEGP"
WAVLM_SHA256 = "51f07e3b94d9e0262a6a675ef5a087be3dd09e8c62e9d886827f44f82fe7f94b"
ECAPA_REVISION = "04c3ffe4fd00b3b7853fd57db44e2e531d4817f2"
ECAPA_SHA256 = "245eb5995cfffd74494862dee33da2b00c1c2579eb0c6703847784e9901ed458"
S3PRL_REVISION = "ec8064b5889f81ca460fbe2c094ce576a6f120b7"
S3PRL_ARCHIVE_SHA256 = (
    "fa182b81c0963d82aa4bd2e567bdfb42ecabebe2ac6bee92e4acc08233b70dbe"
)
S3PRL_MODEL_REVISION = "8cad0b370e7e35f8d56951d95d2be036ea85510c"
S3PRL_WAVLM_SHA256 = (
    "6fb4b3c3e6aa567f0a997b30855859cb81528ee8078802af439f7b2da0bf100f"
)


@dataclass(frozen=True)
class ChunkResult:
    trial: int
    index: int
    input_samples: int
    output_samples: int
    elapsed_seconds: float

    @property
    def deadline_seconds(self) -> float:
        return self.input_samples / SAMPLE_RATE


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verify_file(path: Path, expected_sha256: str) -> None:
    actual = sha256_file(path)
    if actual != expected_sha256:
        raise ValueError(
            f"SHA-256 mismatch for {path.name}: expected {expected_sha256}, got {actual}"
        )


def download(url: str, destination: Path, expected_sha256: str) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists():
        verify_file(destination, expected_sha256)
        return
    temporary = destination.with_suffix(destination.suffix + ".part")
    print(f"download: {destination.name}")
    urllib.request.urlretrieve(url, temporary)
    verify_file(temporary, expected_sha256)
    temporary.replace(destination)


def ensure_meanvc_source(lab_dir: Path) -> Path:
    vendor_dir = lab_dir / "vendor"
    source_dir = vendor_dir / "MeanVC"
    if (source_dir / "src/runtime/run_rt.py").exists():
        return source_dir

    vendor_dir.mkdir(parents=True, exist_ok=True)
    archive = vendor_dir / f"meanvc-{MEANVC_REVISION}.tar.gz"
    download(
        f"https://github.com/ASLP-lab/MeanVC/archive/{MEANVC_REVISION}.tar.gz",
        archive,
        MEANVC_ARCHIVE_SHA256,
    )
    with tempfile.TemporaryDirectory(dir=vendor_dir) as temporary_dir:
        temporary_path = Path(temporary_dir)
        with tarfile.open(archive, "r:gz") as tar:
            base = temporary_path.resolve()
            for member in tar.getmembers():
                resolved = (temporary_path / member.name).resolve()
                if base not in resolved.parents and resolved != base:
                    raise ValueError(f"unsafe archive member: {member.name}")
            tar.extractall(temporary_path)
        extracted = temporary_path / f"MeanVC-{MEANVC_REVISION}"
        shutil.move(str(extracted), source_dir)
    return source_dir


def ensure_s3prl(lab_dir: Path) -> tuple[Path, Path]:
    vendor_dir = lab_dir / "vendor"
    source_dir = vendor_dir / "s3prl"
    if not (source_dir / "s3prl/upstream/wavlm/hubconf.py").exists():
        vendor_dir.mkdir(parents=True, exist_ok=True)
        archive = vendor_dir / f"s3prl-{S3PRL_REVISION}.tar.gz"
        download(
            f"https://github.com/s3prl/s3prl/archive/{S3PRL_REVISION}.tar.gz",
            archive,
            S3PRL_ARCHIVE_SHA256,
        )
        with tempfile.TemporaryDirectory(dir=vendor_dir) as temporary_dir:
            temporary_path = Path(temporary_dir)
            with tarfile.open(archive, "r:gz") as tar:
                base = temporary_path.resolve()
                for member in tar.getmembers():
                    resolved = (temporary_path / member.name).resolve()
                    if base not in resolved.parents and resolved != base:
                        raise ValueError(f"unsafe archive member: {member.name}")
                tar.extractall(temporary_path)
            extracted = temporary_path / f"s3prl-{S3PRL_REVISION}"
            shutil.move(str(extracted), source_dir)

    wavlm_path = lab_dir / "models/s3prl_wavlm_large.pt"
    download(
        "https://huggingface.co/s3prl/converted_ckpts/resolve/"
        f"{S3PRL_MODEL_REVISION}/wavlm_large.pt",
        wavlm_path,
        S3PRL_WAVLM_SHA256,
    )
    return source_dir, wavlm_path


def ensure_models(lab_dir: Path, source_dir: Path) -> Path:
    checkpoint_dir = source_dir / "src/ckpt"
    for filename, digest in MEANVC_FILES.items():
        download(
            "https://huggingface.co/ASLP-lab/MeanVC/resolve/"
            f"{MEANVC_MODEL_REVISION}/{filename}",
            checkpoint_dir / filename,
            digest,
        )

    wavlm_path = (
        source_dir
        / "src/runtime/speaker_verification/ckpt/wavlm_large_finetune.pth"
    )
    wavlm_path.parent.mkdir(parents=True, exist_ok=True)
    if wavlm_path.exists():
        verify_file(wavlm_path, WAVLM_SHA256)
    else:
        print("download: wavlm_large_finetune.pth")
        temporary = wavlm_path.with_suffix(".pth.part")
        result = gdown.download(id=WAVLM_GOOGLE_DRIVE_ID, output=str(temporary), quiet=False)
        if result is None:
            raise RuntimeError("WavLM download failed")
        verify_file(temporary, WAVLM_SHA256)
        temporary.replace(wavlm_path)

    ecapa_path = lab_dir / "models/ecapa_tdnn.onnx"
    download(
        "https://huggingface.co/pranjal-pravesh/ecapa_tdnn_onnx/resolve/"
        f"{ECAPA_REVISION}/ecapa_tdnn.onnx",
        ecapa_path,
        ECAPA_SHA256,
    )
    return ecapa_path


def decode_audio(path: Path) -> np.ndarray:
    result = subprocess.run(
        [
            "ffmpeg",
            "-v",
            "error",
            "-i",
            str(path),
            "-ac",
            "1",
            "-ar",
            str(SAMPLE_RATE),
            "-f",
            "f32le",
            "-",
        ],
        check=True,
        stdout=subprocess.PIPE,
    )
    return np.frombuffer(result.stdout, dtype="<f4").copy()


def concatenate_segments(
    samples: np.ndarray, segments: tuple[tuple[float, float], ...]
) -> np.ndarray:
    pieces = [
        samples[round(start * SAMPLE_RATE) : round(end * SAMPLE_RATE)]
        for start, end in segments
    ]
    return np.concatenate(pieces).astype(np.float32)


def prepare_audio(audio_path: Path, output_dir: Path) -> tuple[np.ndarray, np.ndarray]:
    samples = decode_audio(audio_path)
    source = concatenate_segments(samples, SOURCE_SEGMENTS)
    target = concatenate_segments(samples, TARGET_SEGMENTS)
    output_dir.mkdir(parents=True, exist_ok=True)
    sf.write(output_dir / "source.wav", source, SAMPLE_RATE, subtype="PCM_16")
    sf.write(output_dir / "target_reference.wav", target, SAMPLE_RATE, subtype="PCM_16")
    return source, target


def load_runner_class(
    source_dir: Path, s3prl_source_dir: Path, s3prl_wavlm_path: Path
):
    runtime_dir = source_dir / "src/runtime"
    sys.path.insert(0, str(source_dir))
    sys.path.insert(0, str(runtime_dir))
    sys.path.insert(0, str(s3prl_source_dir))
    sys.modules.setdefault("pyaudio", types.ModuleType("pyaudio"))
    original_torch_hub_load = torch.hub.load

    def pinned_torch_hub_load(repo_or_dir, model, *args, **kwargs):
        if repo_or_dir == "s3prl/s3prl" and model == "wavlm_large":
            wavlm_hub = importlib.import_module("s3prl.upstream.wavlm.hubconf")
            return wavlm_hub.wavlm_local(str(s3prl_wavlm_path))
        return original_torch_hub_load(repo_or_dir, model, *args, **kwargs)

    torch.hub.load = pinned_torch_hub_load
    return importlib.import_module("run_rt").VCRunner


def streaming_chunks(samples: np.ndarray) -> list[np.ndarray]:
    chunks = []
    cursor = 0
    first = True
    while cursor < len(samples):
        size = FIRST_CHUNK_SAMPLES if first else STEADY_CHUNK_SAMPLES
        chunk = samples[cursor : cursor + size]
        if len(chunk) < size:
            chunk = np.pad(chunk, (0, size - len(chunk)))
        chunks.append(chunk.astype(np.float32))
        cursor += size
        first = False
    return chunks


def benchmark(runner, source: np.ndarray) -> tuple[list[ChunkResult], np.ndarray]:
    source_chunks = streaming_chunks(source)

    torch.manual_seed(SEED)
    runner.init_cache()
    runner.inference_one_chunk(source_chunks[0])

    results: list[ChunkResult] = []
    saved_output: list[np.ndarray] = []
    for trial in range(TRIALS):
        torch.manual_seed(SEED + trial)
        runner.init_cache()
        trial_output = []
        for index, chunk in enumerate(source_chunks):
            started = time.perf_counter()
            output = runner.inference_one_chunk(chunk)
            elapsed = time.perf_counter() - started
            results.append(
                ChunkResult(trial, index, len(chunk), len(output), elapsed)
            )
            trial_output.append(np.asarray(output, dtype=np.float32))
        if trial == 0:
            saved_output = trial_output
    return results, np.concatenate(saved_output)


class EcapaTDNN:
    def __init__(self, model_path: Path) -> None:
        verify_file(model_path, ECAPA_SHA256)
        self.session = ort.InferenceSession(
            str(model_path), providers=["CPUExecutionProvider"]
        )

    def embed(self, samples: np.ndarray) -> np.ndarray:
        input_info = self.session.get_inputs()[0]
        rank = len(input_info.shape)
        if rank == 3:
            waveform = samples.reshape(1, 1, -1).astype(np.float32)
        elif rank == 2:
            waveform = samples.reshape(1, -1).astype(np.float32)
        else:
            waveform = samples.astype(np.float32)
        embedding = np.asarray(
            self.session.run(None, {input_info.name: waveform})[0],
            dtype=np.float32,
        ).reshape(-1)
        if embedding.shape != (ECAPA_DIMENSION,):
            raise ValueError(f"unexpected ECAPA embedding shape: {embedding.shape}")
        return embedding / np.linalg.norm(embedding)


def cosine(left: np.ndarray, right: np.ndarray) -> float:
    return float(np.dot(left, right))


def split_turns(
    samples: np.ndarray, segments: tuple[tuple[float, float], ...]
) -> list[np.ndarray]:
    turns = []
    cursor = 0
    for start, end in segments:
        length = round((end - start) * SAMPLE_RATE)
        turns.append(samples[cursor : cursor + length])
        cursor += length
    return turns


def mean_pairwise_similarity(embeddings: list[np.ndarray]) -> float:
    scores = [cosine(left, right) for left, right in combinations(embeddings, 2)]
    return float(np.mean(scores))


def percentile(values: list[float], q: float) -> float:
    return float(np.percentile(np.asarray(values, dtype=np.float64), q))


def dbfs(samples: np.ndarray) -> float:
    rms = float(np.sqrt(np.mean(np.square(samples, dtype=np.float64))))
    return 20 * math.log10(max(rms, 1e-12))


def boundary_metrics(output: np.ndarray, chunk_lengths: list[int]) -> dict[str, float]:
    boundaries = np.cumsum(chunk_lengths)[:-1]
    adjacent = np.abs(np.diff(output.astype(np.float64)))
    boundary_jumps = np.asarray(
        [abs(float(output[index] - output[index - 1])) for index in boundaries]
    )
    return {
        "boundary_count": int(len(boundary_jumps)),
        "boundary_jump_p50": percentile(boundary_jumps.tolist(), 50),
        "boundary_jump_p95": percentile(boundary_jumps.tolist(), 95),
        "all_adjacent_jump_p95": percentile(adjacent.tolist(), 95),
        "max_boundary_jump": float(np.max(boundary_jumps)),
        "max_all_adjacent_jump": float(np.max(adjacent)),
    }


def memory_mb() -> float:
    value = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return value / (1024 * 1024) if sys.platform == "darwin" else value / 1024


def command_output(command: list[str]) -> str:
    return subprocess.run(
        command, check=True, capture_output=True, text=True
    ).stdout.strip()


def build_report(
    audio_path: Path,
    source: np.ndarray,
    target: np.ndarray,
    converted: np.ndarray,
    chunks: list[ChunkResult],
    ecapa: EcapaTDNN,
) -> dict:
    elapsed = [chunk.elapsed_seconds for chunk in chunks]
    steady = [chunk.elapsed_seconds for chunk in chunks if chunk.index > 0]
    first_elapsed = [chunk.elapsed_seconds for chunk in chunks if chunk.index == 0]
    misses = [chunk for chunk in chunks if chunk.elapsed_seconds > chunk.deadline_seconds]

    source_embedding = ecapa.embed(source)
    target_embedding = ecapa.embed(target)
    converted_embedding = ecapa.embed(converted)
    source_turn_embeddings = [
        ecapa.embed(turn) for turn in split_turns(source, SOURCE_SEGMENTS)
    ]
    target_turn_embeddings = [
        ecapa.embed(turn) for turn in split_turns(target, TARGET_SEGMENTS)
    ]
    cross_turn_scores = [
        cosine(source_turn, target_turn)
        for source_turn in source_turn_embeddings
        for target_turn in target_turn_embeddings
    ]

    output_lengths = [
        chunk.output_samples for chunk in chunks if chunk.trial == 0
    ]
    first_input_seconds = FIRST_CHUNK_SAMPLES / SAMPLE_RATE
    return {
        "input": {
            "asset": "tests/assets/mp3/conversation_2speaker_14s_16k.mp3",
            "decoded_duration_seconds": len(decode_audio(audio_path)) / SAMPLE_RATE,
            "source_segments_seconds": SOURCE_SEGMENTS,
            "target_segments_seconds": TARGET_SEGMENTS,
            "source_duration_seconds": len(source) / SAMPLE_RATE,
            "target_duration_seconds": len(target) / SAMPLE_RATE,
        },
        "model": {
            "meanvc_source_revision": MEANVC_REVISION,
            "meanvc_model_revision": MEANVC_MODEL_REVISION,
            "meanvc_files_sha256": MEANVC_FILES,
            "wavlm_sha256": WAVLM_SHA256,
            "ecapa_revision": ECAPA_REVISION,
            "ecapa_sha256": ECAPA_SHA256,
            "s3prl_revision": S3PRL_REVISION,
            "s3prl_model_revision": S3PRL_MODEL_REVISION,
            "s3prl_wavlm_sha256": S3PRL_WAVLM_SHA256,
        },
        "streaming": {
            "sample_rate": SAMPLE_RATE,
            "inference_steps": INFERENCE_STEPS,
            "trials": TRIALS,
            "first_chunk_samples": FIRST_CHUNK_SAMPLES,
            "steady_chunk_samples": STEADY_CHUNK_SAMPLES,
            "measured_chunks": len(chunks),
            "elapsed_p50_ms": percentile(elapsed, 50) * 1000,
            "elapsed_p95_ms": percentile(elapsed, 95) * 1000,
            "elapsed_p99_ms": percentile(elapsed, 99) * 1000,
            "steady_elapsed_p50_ms": percentile(steady, 50) * 1000,
            "steady_elapsed_p95_ms": percentile(steady, 95) * 1000,
            "steady_elapsed_p99_ms": percentile(steady, 99) * 1000,
            "deadline_misses": len(misses),
            "deadline_miss_rate": len(misses) / len(chunks),
            "estimated_first_output_latency_p50_ms": (
                first_input_seconds + percentile(first_elapsed, 50)
            )
            * 1000,
            "estimated_first_output_latency_p95_ms": (
                first_input_seconds + percentile(first_elapsed, 95)
            )
            * 1000,
            "estimated_first_output_latency_max_ms": (
                first_input_seconds + max(first_elapsed)
            )
            * 1000,
            "converted_duration_seconds": len(converted) / SAMPLE_RATE,
            "max_rss_mb": memory_mb(),
            "chunks": [chunk.__dict__ for chunk in chunks],
        },
        "speaker_similarity": {
            "source_to_target": cosine(source_embedding, target_embedding),
            "converted_to_target": cosine(converted_embedding, target_embedding),
            "converted_to_source": cosine(converted_embedding, source_embedding),
            "source_within_turn_mean": mean_pairwise_similarity(
                source_turn_embeddings
            ),
            "target_within_turn_mean": mean_pairwise_similarity(
                target_turn_embeddings
            ),
            "source_target_cross_turn_mean": float(np.mean(cross_turn_scores)),
        },
        "signal": {
            "source_rms_dbfs": dbfs(source),
            "target_rms_dbfs": dbfs(target),
            "converted_rms_dbfs": dbfs(converted),
            "converted_clipped_sample_ratio": float(
                np.mean(np.abs(converted) >= 1.0)
            ),
            **boundary_metrics(converted, output_lengths),
        },
        "environment": {
            "machine": platform.machine(),
            "chip": command_output(["sysctl", "-n", "machdep.cpu.brand_string"]),
            "os": command_output(["sw_vers", "-productVersion"]),
            "python": platform.python_version(),
            "torch": torch.__version__,
            "numpy": np.__version__,
            "onnxruntime": ort.__version__,
            "torch_threads": torch.get_num_threads(),
            "execution": "MeanVC CPU TorchScript; ECAPA CPUExecutionProvider",
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--output", type=Path, default=Path("output"))
    args = parser.parse_args()

    lab_dir = Path(__file__).resolve().parent
    output_dir = (lab_dir / args.output).resolve()
    source, target = prepare_audio(args.audio.resolve(), output_dir)
    source_dir = ensure_meanvc_source(lab_dir)
    s3prl_source_dir, s3prl_wavlm_path = ensure_s3prl(lab_dir)
    ecapa_path = ensure_models(lab_dir, source_dir)

    previous_cwd = Path.cwd()
    try:
        os.chdir(source_dir)
        torch.set_num_threads(1)
        torch.manual_seed(SEED)
        runner_class = load_runner_class(
            source_dir, s3prl_source_dir, s3prl_wavlm_path
        )
        runner = runner_class(
            str(output_dir / "target_reference.wav"), steps=INFERENCE_STEPS
        )
        chunks, converted = benchmark(runner, source)
    finally:
        os.chdir(previous_cwd)

    sf.write(output_dir / "converted.wav", converted, SAMPLE_RATE, subtype="PCM_16")
    ecapa = EcapaTDNN(ecapa_path)
    report = build_report(
        args.audio.resolve(), source, target, converted, chunks, ecapa
    )
    report_path = output_dir / "report.json"
    report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    streaming = report["streaming"]
    similarity = report["speaker_similarity"]
    signal = report["signal"]
    print(f"source duration: {report['input']['source_duration_seconds']:.3f}s")
    print(f"target duration: {report['input']['target_duration_seconds']:.3f}s")
    print(f"measured chunks: {streaming['measured_chunks']}")
    print(
        "steady inference p50/p95/p99: "
        f"{streaming['steady_elapsed_p50_ms']:.1f}/"
        f"{streaming['steady_elapsed_p95_ms']:.1f}/"
        f"{streaming['steady_elapsed_p99_ms']:.1f} ms"
    )
    print(
        f"deadline misses: {streaming['deadline_misses']}/"
        f"{streaming['measured_chunks']}"
    )
    print(
        "speaker cosine source-target/converted-target/converted-source: "
        f"{similarity['source_to_target']:.3f}/"
        f"{similarity['converted_to_target']:.3f}/"
        f"{similarity['converted_to_source']:.3f}"
    )
    print(
        "boundary jump p95 / all adjacent p95: "
        f"{signal['boundary_jump_p95']:.6f}/"
        f"{signal['all_adjacent_jump_p95']:.6f}"
    )
    print(f"report: {report_path.relative_to(lab_dir)}")


if __name__ == "__main__":
    main()
