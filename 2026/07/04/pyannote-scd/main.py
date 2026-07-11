from __future__ import annotations

import argparse
import shutil
import subprocess
import time
from dataclasses import dataclass
from itertools import combinations
from pathlib import Path

import numpy as np
import onnxruntime as ort


SAMPLE_RATE = 16_000
WINDOW_DURATION = 10.0
NUM_SPEAKERS = 3
MAX_SPEAKERS_PER_FRAME = 2
THRESHOLD = 0.5
OVERLAP_MARGIN = 0.1
MIN_CHANGE_MS = 100
MIN_SPEECH_MS = 100
UNKNOWN_SILENCE = -1
UNKNOWN_OVERLAP = -2


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
        expected_frames = max(1, round(len(samples) * 1000 / SAMPLE_RATE / frame_ms))
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
                f"expected 2D model output after squeeze, got {output.shape}"
            )

        candidate_classes = {NUM_SPEAKERS, self.powerset_mapping.shape[0]}
        if output.shape[0] in candidate_classes and output.shape[1] not in candidate_classes:
            output = output.T

        if output.shape[1] == NUM_SPEAKERS:
            return output
        if output.shape[1] != self.powerset_mapping.shape[0]:
            raise ValueError(f"cannot interpret model output shape {output.shape}")

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
        active_indexes = np.flatnonzero(frame >= THRESHOLD)
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
    min_change_frames = max(1, round(MIN_CHANGE_MS / frame_ms))
    min_speech_frames = max(1, round(MIN_SPEECH_MS / frame_ms))
    runs = smooth_short_runs(labels_to_runs(labels), min_change_frames)
    runs = smooth_short_runs(runs, min_speech_frames)

    segments = []
    for run in runs:
        start = run.start_frame * frame_ms / 1000
        end = min(audio_duration, run.end_frame * frame_ms / 1000)
        segments.append(Segment(run.label, start, end))
    if segments:
        segments[-1] = Segment(
            segments[-1].label, segments[-1].start, audio_duration
        )
    return segments


def label_name(label: int) -> str:
    if label == UNKNOWN_OVERLAP:
        return "overlap"
    if label == UNKNOWN_SILENCE:
        return "silence"
    return f"speaker_{label}"


def extract_segments(
    samples: np.ndarray, segments: list[Segment], output_dir: Path
) -> list[Path]:
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    output_paths = []
    for index, segment in enumerate(segments, start=1):
        output_path = output_dir / f"{label_name(segment.label)}_{index:03d}.wav"
        start_sample = round(segment.start * SAMPLE_RATE)
        end_sample = round(segment.end * SAMPLE_RATE)
        pcm = (
            np.clip(samples[start_sample:end_sample], -1.0, 1.0) * 32767
        ).astype("<i2")
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-y",
                "-f",
                "s16le",
                "-ar",
                str(SAMPLE_RATE),
                "-ac",
                "1",
                "-i",
                "-",
                "-c:a",
                "pcm_s16le",
                str(output_path),
            ],
            check=True,
            input=pcm.tobytes(),
        )
        output_paths.append(output_path)
    return output_paths


def parse_args() -> argparse.Namespace:
    lab_dir = Path(__file__).resolve().parent
    root_dir = lab_dir.parents[3]
    parser = argparse.ArgumentParser(
        description="Detect speaker changes with Pyannote Segmentation 3.0."
    )
    parser.add_argument(
        "--audio",
        type=Path,
        default=root_dir / "tests/assets/mp3/conversation_2speaker_14s_16k.mp3",
    )
    parser.add_argument("--model", type=Path, default=lab_dir / "model.onnx")
    parser.add_argument("--output", type=Path, default=lab_dir / "output")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if shutil.which("ffmpeg") is None:
        raise SystemExit("ffmpeg is required but was not found")
    if not args.audio.is_file():
        raise SystemExit(f"audio file not found: {args.audio}")
    if not args.model.is_file():
        raise SystemExit(f"model file not found: {args.model}")

    samples = decode_audio(args.audio)
    if len(samples) == 0:
        raise SystemExit(f"decoded audio is empty: {args.audio}")

    audio_duration = len(samples) / SAMPLE_RATE
    model = PyannoteSCD(args.model)
    started_at = time.perf_counter()
    probabilities, frame_ms = model.predict(samples)
    segments = detect_segments(probabilities, frame_ms, audio_duration)
    elapsed = time.perf_counter() - started_at
    output_paths = extract_segments(samples, segments, args.output)

    print(f"audio: {args.audio}")
    print(f"audio duration: {audio_duration:.3f}s")
    print(f"SCD elapsed: {elapsed:.3f}s")
    print(f"SCD real-time factor: {elapsed / audio_duration:.3f}x")
    print(f"frame duration: {frame_ms:.3f}ms")
    print(f"segments: {len(segments)}")
    for index, (segment, output_path) in enumerate(
        zip(segments, output_paths, strict=True), start=1
    ):
        print(
            f"{index:03d}: {segment.start:7.3f}s - {segment.end:7.3f}s "
            f"({segment.duration:6.3f}s) {label_name(segment.label):>9} "
            f"-> {output_path}"
        )


if __name__ == "__main__":
    main()
