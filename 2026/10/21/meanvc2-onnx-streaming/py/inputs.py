"""Inputs shared by the comparison, the benchmarks and the app fixtures.

- asset: speaker 1 of the shared conversation asset (same split as the earlier
  MeanVC labs); the target reference is speaker 2 of the same asset
- kyoko: one sentence of macOS `say -v Kyoko` (16 kHz), as in the file-mode lab
- long: Kyoko sentences joined to about 70 s, so that the DiT offset passes
  4000 frames and the upstream cache reset runs once
"""
from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path

import librosa
import numpy as np
import soundfile as sf

LAB = Path(__file__).resolve().parents[1]
# labs/tests/assets (the lab sits at labs/YYYY/MM/DD/<slug>); only needed when the cached inputs are missing
ASSET = LAB.parent.parent.parent.parent / "tests/assets/mp3/conversation_2speaker_14s_16k.mp3"
SOURCE_SPANS = [(0.000, 1.851), (4.737, 7.317), (9.677, 11.834)]
TARGET_SPANS = [(1.851, 4.737), (7.317, 9.677), (11.834, 14.171)]
TARGET_DESCRIPTION = "speaker 2 of tests/assets/mp3/conversation_2speaker_14s_16k.mp3 (7.6 s)"

KYOKO_SENTENCE = "こんにちは。今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？"
LONG_SENTENCES = [
    KYOKO_SENTENCE,
    "明日の会議は午後三時からです。資料は二十ページほどなので、先に目を通しておいてください。",
    "週末は友だちと海へ行く予定です。天気がよければ、バーベキューもしたいと思っています。",
    "このアプリでは、声の変換を流しながら行います。百六十ミリ秒ずつ、少しずつ変えていきます。",
    "駅から歩いて五分のところに、新しいパン屋さんができました。クロワッサンがとてもおいしいです。",
    "ちょっと待ってください。もう一度、最初から説明してもらえますか？",
    "去年の夏は、北海道を一週間かけて旅行しました。ラベンダー畑がきれいでした。",
    "おなかがすいたので、そろそろお昼ごはんにしましょう。ラーメンとうどん、どちらがいいですか？",
]


def _asset() -> np.ndarray:
    audio, _ = librosa.load(ASSET, sr=16000, mono=True)
    return audio.astype(np.float32)


def _cut(audio, spans):
    return np.concatenate([audio[int(a * 16000):int(b * 16000)] for a, b in spans])


def target_audio() -> np.ndarray:
    return _cut(_asset(), TARGET_SPANS)


def say(text: str, voice: str = "Kyoko") -> np.ndarray:
    cache = LAB / "build/inputs"
    cache.mkdir(parents=True, exist_ok=True)
    path = cache / f"say_{voice}_{hashlib.sha256(text.encode()).hexdigest()[:12]}.wav"
    if not path.exists():
        subprocess.run(["say", "-v", voice, "-o", str(path), "--file-format=WAVE", "--data-format=LEI16@16000", text],
                       check=True)
    audio, sr = sf.read(path, dtype="float32")
    assert sr == 16000
    return audio


def source(case: str) -> tuple[np.ndarray, str]:
    cached = LAB / "build/inputs" / f"{case}.wav"
    if cached.exists():
        audio, _ = sf.read(cached, dtype="float32")
    else:
        if case == "asset":
            audio = _cut(_asset(), SOURCE_SPANS)
        elif case == "kyoko":
            audio = say(KYOKO_SENTENCE)
        elif case == "long":
            parts = []
            for text in LONG_SENTENCES * 2:
                parts += [say(text), np.zeros(4000, np.float32)]
            audio = np.concatenate(parts)
            audio = audio[: 70 * 16000] if len(audio) > 70 * 16000 else audio
        else:
            raise ValueError(case)
        cached.parent.mkdir(parents=True, exist_ok=True)
        sf.write(cached, audio, 16000, subtype="FLOAT")
    desc = {"asset": "speaker 1 of the shared conversation asset",
            "kyoko": f"macOS say -v Kyoko: {KYOKO_SENTENCE}",
            "long": "macOS say -v Kyoko, 8 sentences twice with 0.25 s gaps, cut at 70 s"}[case]
    return audio, desc
