"""Speaker identification for the lab: ECAPA-TDNN (ONNX, raw 16 kHz waveform in, 192-d out)."""
import subprocess, wave
from pathlib import Path

import numpy as np
import onnxruntime as ort

MODELS = Path(__file__).parent / 'work' / 'models'
SR = 16_000


def read_wav(path):
    with wave.open(str(path)) as w:
        assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2
        return np.frombuffer(w.readframes(w.getnframes()), np.int16).astype(np.float32) / 32768


def say(voice, text, path, rate=None):
    """macOS `say` straight to 16 kHz mono PCM16, with leading/trailing silence trimmed."""
    path = Path(path)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        cmd = ['say', '-v', voice, '-o', str(path), '--data-format=LEI16@16000']
        if rate:
            cmd += ['-r', str(rate)]
        subprocess.run(cmd + [text], check=True)
    x = read_wav(path)
    loud = np.flatnonzero(np.abs(x) > 0.01)
    return x[max(0, loud[0] - 800): loud[-1] + 800] if len(loud) else x


class Ecapa:
    def __init__(self):
        self.s = ort.InferenceSession(str(MODELS / 'ecapa_tdnn.onnx'))
        self.inp = self.s.get_inputs()[0]

    def embed(self, x):
        x = np.asarray(x, np.float32)
        x = x.reshape((1,) * (len(self.inp.shape) - 1) + (-1,))
        v = np.asarray(self.s.run(None, {self.inp.name: x})[0], np.float32).reshape(-1)
        return v / (np.linalg.norm(v) + 1e-9)


class Identifier:
    """Enroll each person from a few clips; identify a clip by the best cosine similarity."""
    def __init__(self, ecapa, threshold):
        self.ecapa, self.threshold, self.people = ecapa, threshold, {}

    def enroll(self, name, clips):
        v = np.mean([self.ecapa.embed(c) for c in clips], axis=0)
        self.people[name] = v / np.linalg.norm(v)

    def identify(self, x):
        e = self.ecapa.embed(x)
        scores = {n: float(e @ v) for n, v in self.people.items()}
        best = max(scores, key=scores.get)
        return (best if scores[best] >= self.threshold else None), scores
