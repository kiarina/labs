"""Inputs shared by every engine: the reference voice, its transcript, the sentences, and how results are reported."""

from __future__ import annotations

import os
import subprocess
import sys
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np
import soundfile as sf

LAB_DIR = Path(__file__).resolve().parents[1]
SAMPLE_RATE = 24_000
# Speaker 1 of the shared two-speaker sample, as in the earlier labs (japanese-zero-shot-tts-compare, qwen3-tts-mlx-live-clone).
SAMPLE_ASSET = LAB_DIR.parents[3] / "tests/assets/mp3/conversation_2speaker_14s_16k.mp3"
SPEAKER1_SEGMENTS = [(0.000, 1.851), (4.737, 7.317), (9.677, 11.834)]
REFERENCE_TEXT = "もしもし、もう駅に着いた？こっちはまだ電車。あと5分くらいかな。助かる。今日は結構寒いね。"
# The seven example sentences of japanese-zero-shot-tts-compare.
TEXTS = [
    "こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？",
    "ちょっと待って。チケットはもう買ってあるから、ゆっくり行こうよ。",
    "明日の朝、七時三十分に、東京駅の八重洲口で待ち合わせしましょう。",
    "えっ、本当に？すごい！ずっと楽しみにしてたんだ、ありがとう！",
    "この機能を使うには、設定の画面を開いて、スピーカーで話すをオンにしてください。",
    "MacBook の Bluetooth をオフにしてから、もう一度 iPhone とつないでみて。",
    "昔々、ある山のふもとに、小さな村がありました。村の人たちは毎朝、川で水をくみ、畑を耕して、静かに暮らしていました。",
]
WARMUP_TEXT = "こんにちは。"


def reference_wav() -> Path:
    """Speaker 1 at 24 kHz mono (afconvert, as the earlier labs prepare it)."""
    output = LAB_DIR / "output/reference-speaker1.wav"
    if not output.exists():
        output.parent.mkdir(parents=True, exist_ok=True)
        decoded = output.with_suffix(".full.wav")
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEI16@{SAMPLE_RATE}", "-c", "1", str(SAMPLE_ASSET), str(decoded)], check=True
        )
        audio, rate = sf.read(decoded, dtype="float32")
        decoded.unlink()
        pieces = [audio[int(start * rate) : int(end * rate)] for start, end in SPEAKER1_SEGMENTS]
        sf.write(output, np.concatenate(pieces), rate, subtype="PCM_16")
    return output


def footprint_gb() -> float:
    """phys_footprint of this process (what Activity Monitor shows as Memory), in GB. On Windows, private bytes."""
    if sys.platform == "win32":
        import psutil  # noqa: PLC0415

        return psutil.Process().memory_info().private / 1e9
    output = subprocess.run(["footprint", "-p", str(os.getpid())], capture_output=True, text=True).stdout
    for line in output.splitlines():
        if "phys_footprint:" in line:
            value, unit = line.split("phys_footprint:")[1].split()[:2]
            return float(value) * {"KB": 1e-6, "MB": 1e-3, "GB": 1.0}[unit]
    return float("nan")


@dataclass
class Synthesis:
    audio: np.ndarray
    seconds: float  # wall time from the request to the last sample
    arrivals: list[tuple[float, float]] = field(default_factory=list)  # (seconds since the request, chunk duration)
    frames: int = 0  # 12.5 Hz codec frames generated
    extra: dict = field(default_factory=dict)


def playback_stalls(arrivals: list[tuple[float, float]]) -> float:
    """Seconds of silence if playback starts at the first chunk and plays chunks back to back."""
    play_end, stalls = arrivals[0][0], 0.0
    for arrived, duration in arrivals:
        if arrived > play_end:
            stalls += arrived - play_end
            play_end = arrived
        play_end += duration
    return stalls
