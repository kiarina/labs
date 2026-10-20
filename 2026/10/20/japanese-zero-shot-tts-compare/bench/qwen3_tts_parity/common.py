"""Inputs shared by both sides of the comparison (no torch / mlx imports)."""

from pathlib import Path

LAB = Path(__file__).resolve().parents[2]
REFERENCE = LAB / "output/bench-reference-speaker1.wav"  # sample speaker 1, 24 kHz mono (6.6 s)
REFERENCE_TEXT = "もしもし、もう駅に着いた？こっちはまだ電車。あと5分くらいかな。助かる。今日は結構寒いね。"
TEXT = "こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？"

# sentences for the generation comparison (from the web UI's examples)
TEXTS = [
    TEXT,
    "ちょっと待って。チケットはもう買ってあるから、ゆっくり行こうよ。",
    "昔々、ある山のふもとに、小さな村がありました。村の人たちは毎朝、川で水をくみ、畑を耕して、静かに暮らしていました。",
]
SEEDS = range(5)


def code_stats(codes):
    """codes [T, 16] -> repeats of the first codebook (same as the previous frame) and distinct ratio."""
    first = [int(c) for c in codes[:, 0]]
    repeats = sum(a == b for a, b in zip(first, first[1:])) / max(len(first) - 1, 1)
    return {"frames": len(first), "repeat_rate": repeats, "distinct_ratio": len(set(first)) / max(len(first), 1)}
