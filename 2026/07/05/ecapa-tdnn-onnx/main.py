from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import time
import wave
from dataclasses import dataclass
from itertools import combinations
from pathlib import Path

import numpy as np
import onnxruntime as ort


SAMPLE_RATE = 16_000
WINDOW_DURATION = 10.0
NUM_SPEAKERS = 3
MAX_SPEAKERS_PER_FRAME = 2
SCD_THRESHOLD = 0.5
OVERLAP_MARGIN = 0.1
MIN_CHANGE_MS = 100
MIN_SPEECH_MS = 100
SIMILARITY_THRESHOLD = 0.45
EMBEDDING_DIMENSION = 192
UNKNOWN_SILENCE = -1
UNKNOWN_OVERLAP = -2
EXPECTED_ECAPA_SHA256 = (
    "245eb5995cfffd74494862dee33da2b00c1c2579eb0c6703847784e9901ed458"
)


@dataclass(frozen=True)
class Segment:
    label: int
    start: float
    end: float

    @property
    def duration(self) -> float:
        return self.end - self.start


@dataclass(frozen=True)
class Run:
    label: int
    start_frame: int
    end_frame: int

    @property
    def frame_count(self) -> int:
        return self.end_frame - self.start_frame


@dataclass(frozen=True)
class GroupAssignment:
    group: int
    best_score: float | None


class PyannoteSCD:
    def __init__(self, model_path: Path) -> None:
        self.session = ort.InferenceSession(
            str(model_path), providers=["CPUExecutionProvider"]
        )
        self.powerset_mapping = self._build_powerset_mapping()

    def predict(self, samples: np.ndarray) -> tuple[np.ndarray, float]:
        window_samples = round(WINDOW_DURATION * SAMPLE_RATE)
        chunk_probabilities = []
        for start in range(0, len(samples), window_samples):
            chunk = samples[start : start + window_samples]
            if len(chunk) < window_samples:
                chunk = np.pad(chunk, (0, window_samples - len(chunk)))
            chunk_probabilities.append(self._predict_chunk(chunk))

        probabilities = np.concatenate(chunk_probabilities, axis=0)
        frame_ms = WINDOW_DURATION * 1000 / chunk_probabilities[0].shape[0]
        expected_frames = max(
            1, round(len(samples) * 1000 / SAMPLE_RATE / frame_ms)
        )
        return probabilities[:expected_frames].astype(np.float32), frame_ms

    def _predict_chunk(self, samples: np.ndarray) -> np.ndarray:
        input_info = self.session.get_inputs()[0]
        input_names = {item.name for item in self.session.get_inputs()}
        rank = len(input_info.shape)
        if rank == 3:
            waveform = samples.reshape(1, 1, -1).astype(np.float32)
        elif rank == 2:
            waveform = samples.reshape(1, -1).astype(np.float32)
        else:
            waveform = samples.astype(np.float32)

        inputs: dict[str, np.ndarray] = {input_info.name: waveform}
        if "sample_rate" in input_names:
            inputs["sample_rate"] = np.array(SAMPLE_RATE, dtype=np.int64)
        if "sr" in input_names:
            inputs["sr"] = np.array(SAMPLE_RATE, dtype=np.int64)

        output = np.squeeze(np.asarray(self.session.run(None, inputs)[0], np.float32))
        if output.ndim != 2:
            raise ValueError(
                f"expected 2D SCD output after squeeze, got {output.shape}"
            )

        candidate_classes = {NUM_SPEAKERS, self.powerset_mapping.shape[0]}
        if (
            output.shape[0] in candidate_classes
            and output.shape[1] not in candidate_classes
        ):
            output = output.T
        if output.shape[1] == NUM_SPEAKERS:
            return output
        if output.shape[1] != self.powerset_mapping.shape[0]:
            raise ValueError(f"cannot interpret SCD output shape {output.shape}")
        return np.exp(output) @ self.powerset_mapping

    @staticmethod
    def _build_powerset_mapping() -> np.ndarray:
        rows = []
        for set_size in range(MAX_SPEAKERS_PER_FRAME + 1):
            for current_set in combinations(range(NUM_SPEAKERS), set_size):
                row = [0.0] * NUM_SPEAKERS
                for speaker_index in current_set:
                    row[speaker_index] = 1.0
                rows.append(row)
        return np.asarray(rows, dtype=np.float32)


class EcapaTDNN:
    def __init__(self, model_path: Path) -> None:
        actual_sha256 = sha256_file(model_path)
        if actual_sha256 != EXPECTED_ECAPA_SHA256:
            raise ValueError(
                "ECAPA-TDNN model SHA-256 mismatch: "
                f"expected {EXPECTED_ECAPA_SHA256}, got {actual_sha256}"
            )
        self.model_sha256 = actual_sha256
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
        if embedding.shape != (EMBEDDING_DIMENSION,):
            raise ValueError(
                f"expected {EMBEDDING_DIMENSION}-dimensional embedding, "
                f"got {embedding.shape}"
            )
        norm = float(np.linalg.norm(embedding))
        if not np.isfinite(norm) or norm == 0:
            raise ValueError(f"cannot normalize embedding with norm {norm}")
        return embedding / norm


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


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
    return np.frombuffer(result.stdout, dtype="<f4")


def detect_labels(probabilities: np.ndarray) -> list[int]:
    labels = []
    for frame in probabilities:
        active_indexes = np.flatnonzero(frame >= SCD_THRESHOLD)
        if len(active_indexes) == 0:
            labels.append(UNKNOWN_SILENCE)
            continue
        ordered = np.argsort(frame)[::-1]
        top_index = int(ordered[0])
        if len(active_indexes) >= 2:
            second_index = int(ordered[1])
            if float(frame[top_index] - frame[second_index]) <= OVERLAP_MARGIN:
                labels.append(UNKNOWN_OVERLAP)
                continue
        labels.append(top_index)
    return labels


def merge_silence(labels: list[int]) -> list[int]:
    if not labels or all(label == UNKNOWN_SILENCE for label in labels):
        return labels
    merged = labels.copy()
    index = 0
    while index < len(merged):
        if merged[index] != UNKNOWN_SILENCE:
            index += 1
            continue
        start = index
        while index < len(merged) and merged[index] == UNKNOWN_SILENCE:
            index += 1
        end = index
        previous_label = merged[start - 1] if start > 0 else None
        next_label = merged[end] if end < len(merged) else None
        if previous_label is None:
            fill_point = start
        elif next_label is None or previous_label == next_label:
            fill_point = end
        else:
            fill_point = start + (end - start) // 2
        for fill_index in range(start, end):
            if fill_index < fill_point and previous_label is not None:
                merged[fill_index] = previous_label
            elif next_label is not None:
                merged[fill_index] = next_label
            elif previous_label is not None:
                merged[fill_index] = previous_label
    return merged


def labels_to_runs(labels: list[int]) -> list[Run]:
    if not labels:
        return []
    runs = []
    start_frame = 0
    current_label = labels[0]
    for index, label in enumerate(labels[1:], start=1):
        if label != current_label:
            runs.append(Run(current_label, start_frame, index))
            start_frame = index
            current_label = label
    runs.append(Run(current_label, start_frame, len(labels)))
    return runs


def smooth_short_runs(runs: list[Run], min_frames: int) -> list[Run]:
    if min_frames <= 1 or len(runs) <= 1:
        return runs
    labels = [run.label for run in runs for _ in range(run.frame_count)]
    for index, run in enumerate(runs):
        if run.frame_count >= min_frames:
            continue
        previous = runs[index - 1] if index > 0 else None
        following = runs[index + 1] if index + 1 < len(runs) else None
        if previous is not None and following is not None:
            if previous.label == following.label:
                replacement = previous.label
            elif previous.frame_count >= following.frame_count:
                replacement = previous.label
            else:
                replacement = following.label
        elif previous is not None:
            replacement = previous.label
        elif following is not None:
            replacement = following.label
        else:
            replacement = run.label
        labels[run.start_frame : run.end_frame] = [replacement] * run.frame_count
    return labels_to_runs(labels)


def detect_segments(
    probabilities: np.ndarray, frame_ms: float, audio_duration: float
) -> list[Segment]:
    labels = merge_silence(detect_labels(probabilities))
    runs = smooth_short_runs(
        labels_to_runs(labels), max(1, round(MIN_CHANGE_MS / frame_ms))
    )
    runs = smooth_short_runs(runs, max(1, round(MIN_SPEECH_MS / frame_ms)))
    segments = [
        Segment(
            run.label,
            run.start_frame * frame_ms / 1000,
            min(audio_duration, run.end_frame * frame_ms / 1000),
        )
        for run in runs
    ]
    if segments:
        segments[-1] = Segment(
            segments[-1].label, segments[-1].start, audio_duration
        )
    return segments


def write_segments(
    samples: np.ndarray, segments: list[Segment], output_dir: Path
) -> tuple[list[Path], list[np.ndarray]]:
    if output_dir.parent.exists():
        shutil.rmtree(output_dir.parent)
    output_dir.mkdir(parents=True)
    paths = []
    segment_samples = []
    for index, segment in enumerate(segments, start=1):
        start_sample = round(segment.start * SAMPLE_RATE)
        end_sample = round(segment.end * SAMPLE_RATE)
        current_samples = samples[start_sample:end_sample].copy()
        pcm = (np.clip(current_samples, -1.0, 1.0) * 32767).astype("<i2")
        path = output_dir / f"{index}.wav"
        with wave.open(str(path), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(SAMPLE_RATE)
            wav.writeframes(pcm.tobytes())
        paths.append(path)
        segment_samples.append(current_samples)
    return paths, segment_samples


def cosine_similarity(left: np.ndarray, right: np.ndarray) -> float:
    return float(np.dot(left, right))


def group_embeddings(
    embeddings: list[np.ndarray], threshold: float
) -> tuple[list[GroupAssignment], list[list[np.ndarray]]]:
    groups: list[list[np.ndarray]] = []
    assignments = []
    for embedding in embeddings:
        best_group = -1
        best_score = -1.0
        for index, group in enumerate(groups):
            score = max(cosine_similarity(embedding, member) for member in group)
            if score > best_score:
                best_group = index
                best_score = score
        if best_group >= 0 and best_score >= threshold:
            groups[best_group].append(embedding)
            assignments.append(GroupAssignment(best_group, best_score))
        else:
            groups.append([embedding])
            assignments.append(
                GroupAssignment(len(groups) - 1, None if best_group < 0 else best_score)
            )
    return assignments, groups


def similarity_matrix(embeddings: list[np.ndarray]) -> list[list[float]]:
    return [
        [cosine_similarity(left, right) for right in embeddings]
        for left in embeddings
    ]


def parse_args() -> argparse.Namespace:
    lab_dir = Path(__file__).resolve().parent
    root_dir = lab_dir.parents[3]
    parser = argparse.ArgumentParser(
        description="Group Pyannote SCD segments using ECAPA-TDNN embeddings."
    )
    parser.add_argument(
        "--audio",
        type=Path,
        default=root_dir / "assets/mp3/conversation_2speaker_14s_16k.mp3",
    )
    parser.add_argument("--scd-model", type=Path, default=lab_dir / "scd.onnx")
    parser.add_argument("--ecapa-model", type=Path, default=lab_dir / "ecapa_tdnn.onnx")
    parser.add_argument("--output", type=Path, default=lab_dir / "output")
    parser.add_argument(
        "--similarity-threshold", type=float, default=SIMILARITY_THRESHOLD
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if shutil.which("ffmpeg") is None:
        raise SystemExit("ffmpeg is required but was not found")
    for label, path in (
        ("audio", args.audio),
        ("SCD model", args.scd_model),
        ("ECAPA-TDNN model", args.ecapa_model),
    ):
        if not path.is_file():
            raise SystemExit(f"{label} file not found: {path}")

    samples = decode_audio(args.audio)
    if len(samples) == 0:
        raise SystemExit(f"decoded audio is empty: {args.audio}")
    audio_duration = len(samples) / SAMPLE_RATE

    scd = PyannoteSCD(args.scd_model)
    scd_started_at = time.perf_counter()
    probabilities, frame_ms = scd.predict(samples)
    segments = detect_segments(probabilities, frame_ms, audio_duration)
    scd_elapsed = time.perf_counter() - scd_started_at
    paths, segment_samples = write_segments(
        samples, segments, args.output / "segments"
    )

    ecapa = EcapaTDNN(args.ecapa_model)
    embedding_started_at = time.perf_counter()
    embeddings = [ecapa.embed(current) for current in segment_samples]
    embedding_elapsed = time.perf_counter() - embedding_started_at
    assignments, groups = group_embeddings(
        embeddings, args.similarity_threshold
    )
    matrix = similarity_matrix(embeddings)

    report = {
        "audio": str(args.audio),
        "audio_duration_seconds": audio_duration,
        "models": {
            "scd": str(args.scd_model),
            "ecapa_tdnn": str(args.ecapa_model),
            "ecapa_tdnn_sha256": ecapa.model_sha256,
        },
        "settings": {
            "sample_rate": SAMPLE_RATE,
            "similarity_threshold": args.similarity_threshold,
            "embedding_dimension": EMBEDDING_DIMENSION,
        },
        "timing": {
            "scd_seconds": scd_elapsed,
            "embedding_seconds": embedding_elapsed,
            "embedding_real_time_factor": embedding_elapsed / audio_duration,
        },
        "group_count": len(groups),
        "segments": [
            {
                "index": index,
                "path": str(path),
                "start": segment.start,
                "end": segment.end,
                "duration": segment.duration,
                "scd_label": segment.label,
                "group": assignment.group,
                "best_score": assignment.best_score,
                "embedding_norm": float(np.linalg.norm(embedding)),
            }
            for index, (path, segment, assignment, embedding) in enumerate(
                zip(paths, segments, assignments, embeddings, strict=True), start=1
            )
        ],
        "cosine_similarity_matrix": matrix,
    }
    report_path = args.output / "groups.json"
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

    print(f"audio: {args.audio}")
    print(f"audio duration: {audio_duration:.3f}s")
    print(f"SCD elapsed: {scd_elapsed:.3f}s")
    print(f"SCD real-time factor: {scd_elapsed / audio_duration:.3f}x")
    print(f"embedding elapsed: {embedding_elapsed:.3f}s")
    print(f"embedding real-time factor: {embedding_elapsed / audio_duration:.3f}x")
    print(f"similarity threshold: {args.similarity_threshold:.3f}")
    print(f"segments: {len(segments)}")
    print(f"groups: {len(groups)}")
    for index, (path, segment, assignment) in enumerate(
        zip(paths, segments, assignments, strict=True), start=1
    ):
        score = "new" if assignment.best_score is None else f"{assignment.best_score:.3f}"
        print(
            f"{index}: {segment.start:7.3f}s - {segment.end:7.3f}s "
            f"({segment.duration:6.3f}s) group={assignment.group} "
            f"best_score={score:>5} -> {path}"
        )
    print(f"report: {report_path}")


if __name__ == "__main__":
    main()
