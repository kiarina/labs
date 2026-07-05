from __future__ import annotations

import argparse
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import onnxruntime as ort


SAMPLE_RATE = 16_000
CHUNK_SIZE = 512
CONTEXT_SIZE = 64


@dataclass(frozen=True)
class SpeechSegment:
    start: float
    end: float

    @property
    def duration(self) -> float:
        return self.end - self.start


class SileroVAD:
    def __init__(self, model_path: Path) -> None:
        self.session = ort.InferenceSession(
            str(model_path), providers=["CPUExecutionProvider"]
        )
        self.state = np.zeros((2, 1, 128), dtype=np.float32)
        self.context = np.zeros((1, CONTEXT_SIZE), dtype=np.float32)

    def predict(self, chunk: np.ndarray) -> float:
        samples = chunk.reshape(1, -1).astype(np.float32)
        samples = np.concatenate((self.context, samples), axis=1)
        input_names = {item.name for item in self.session.get_inputs()}
        audio_name = next(
            (name for name in ("input", "audio", "x") if name in input_names),
            self.session.get_inputs()[0].name,
        )
        inputs: dict[str, np.ndarray] = {audio_name: samples}
        if "state" in input_names:
            inputs["state"] = self.state
        if "sr" in input_names:
            inputs["sr"] = np.array(SAMPLE_RATE, dtype=np.int64)

        outputs = self.session.run(None, inputs)
        output_names = [item.name for item in self.session.get_outputs()]
        for index, name in enumerate(output_names):
            if name.lower().startswith("state"):
                self.state = np.asarray(outputs[index], dtype=np.float32)
                break
        else:
            if len(outputs) > 1:
                self.state = np.asarray(outputs[1], dtype=np.float32)

        self.context = samples[:, -CONTEXT_SIZE:]
        return float(np.asarray(outputs[0]).reshape(-1)[0])


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


def speech_probabilities(samples: np.ndarray, model: SileroVAD) -> list[float]:
    probabilities = []
    for offset in range(0, len(samples), CHUNK_SIZE):
        chunk = samples[offset : offset + CHUNK_SIZE]
        if len(chunk) < CHUNK_SIZE:
            chunk = np.pad(chunk, (0, CHUNK_SIZE - len(chunk)))
        probabilities.append(model.predict(chunk))
    return probabilities


def detect_segments(
    probabilities: list[float],
    audio_duration: float,
    threshold: float = 0.5,
    min_silence_ms: int = 100,
    min_speech_ms: int = 250,
    speech_pad_ms: int = 30,
) -> list[SpeechSegment]:
    negative_threshold = max(threshold - 0.15, 0.01)
    min_silence_samples = SAMPLE_RATE * min_silence_ms / 1000
    min_speech_samples = SAMPLE_RATE * min_speech_ms / 1000
    pad_samples = SAMPLE_RATE * speech_pad_ms / 1000
    triggered = False
    start = 0
    possible_end = 0
    raw_segments: list[tuple[int, int]] = []

    for index, probability in enumerate(probabilities):
        current = index * CHUNK_SIZE
        if probability >= threshold:
            possible_end = 0
            if not triggered:
                triggered = True
                start = current
            continue

        if triggered and probability < negative_threshold:
            if possible_end == 0:
                possible_end = current
            if current - possible_end >= min_silence_samples:
                if possible_end - start >= min_speech_samples:
                    raw_segments.append((start, possible_end))
                triggered = False
                possible_end = 0

    audio_samples = int(audio_duration * SAMPLE_RATE)
    if triggered and audio_samples - start >= min_speech_samples:
        raw_segments.append((start, audio_samples))

    segments = []
    for index, (raw_start, raw_end) in enumerate(raw_segments):
        padded_start = max(0, raw_start - int(pad_samples))
        padded_end = min(audio_samples, raw_end + int(pad_samples))
        if index > 0:
            previous_end = int(segments[-1].end * SAMPLE_RATE)
            if padded_start < previous_end:
                midpoint = (raw_start + raw_segments[index - 1][1]) // 2
                previous = segments[-1]
                segments[-1] = SpeechSegment(previous.start, midpoint / SAMPLE_RATE)
                padded_start = midpoint
        segments.append(
            SpeechSegment(padded_start / SAMPLE_RATE, padded_end / SAMPLE_RATE)
        )
    return segments


def extract_segments(
    audio_path: Path, segments: list[SpeechSegment], output_dir: Path
) -> None:
    if output_dir.exists():
        shutil.rmtree(output_dir)
    output_dir.mkdir(parents=True)

    for index, segment in enumerate(segments, start=1):
        output_path = output_dir / f"speech_{index:03d}.wav"
        subprocess.run(
            [
                "ffmpeg",
                "-v",
                "error",
                "-y",
                "-ss",
                f"{segment.start:.3f}",
                "-i",
                str(audio_path),
                "-t",
                f"{segment.duration:.3f}",
                "-ac",
                "1",
                "-ar",
                str(SAMPLE_RATE),
                "-c:a",
                "pcm_s16le",
                str(output_path),
            ],
            check=True,
        )


def parse_args() -> argparse.Namespace:
    lab_dir = Path(__file__).resolve().parent
    root_dir = lab_dir.parents[3]
    parser = argparse.ArgumentParser(
        description="Detect speech with Silero VAD and extract each segment as WAV."
    )
    parser.add_argument(
        "--audio",
        type=Path,
        default=root_dir / "assets/mp3/conversation_2speaker_14s_16k.mp3",
    )
    parser.add_argument("--model", type=Path, default=lab_dir / "silero_vad.onnx")
    parser.add_argument("--output", type=Path, default=lab_dir / "output")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    for command in ("ffmpeg",):
        if shutil.which(command) is None:
            raise SystemExit(f"{command} is required but was not found")
    if not args.audio.is_file():
        raise SystemExit(f"audio file not found: {args.audio}")
    if not args.model.is_file():
        raise SystemExit(f"model file not found: {args.model}")

    samples = decode_audio(args.audio)
    probabilities = speech_probabilities(samples, SileroVAD(args.model))
    segments = detect_segments(probabilities, len(samples) / SAMPLE_RATE)
    extract_segments(args.audio, segments, args.output)

    print(f"audio: {args.audio}")
    print(f"speech segments: {len(segments)}")
    for index, segment in enumerate(segments, start=1):
        print(
            f"{index:03d}: {segment.start:7.3f}s - {segment.end:7.3f}s "
            f"({segment.duration:6.3f}s) -> "
            f"{args.output / f'speech_{index:03d}.wav'}"
        )


if __name__ == "__main__":
    main()
