"""llama.cpp upstream (`llama-tts`, Qwen3-TTS support from ggml-org/llama.cpp#26254), release binaries pinned in download.py.

`llama-tts` is a CLI: every sentence loads the model again, so the wall time includes loading (the load alone is measured
separately by synthesizing the warm-up sentence). It takes a speaker reference file and no transcript, and writes a WAV
when done (no streaming), so "first audio" is the whole run.
"""

from __future__ import annotations

import subprocess
import tempfile
import time
from pathlib import Path

import numpy as np
import soundfile as sf

from download import LAB_DIR, llama_bin, llama_gguf

from .common import SAMPLE_RATE, Synthesis, reference_wav


class Engine:
    def __init__(self, quant: str = "Q8_0") -> None:
        self.quant = quant
        self.name = f"llama-tts-1.7b-{quant}"
        self.description = f"llama.cpp llama-tts (release binaries), ggml-org Qwen3-TTS 1.7B Base {quant}, speaker file only"

    def load(self) -> None:
        self.exe = llama_bin()
        self.model, self.mmproj = llama_gguf(self.quant)
        self.log = LAB_DIR / f"output/{self.name}.log"

    def synthesize(self, text: str, seed: int) -> Synthesis:
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory) / "out.wav"
            args = [
                str(self.exe), "-m", self.model, "-mm", self.mmproj, "-p", text, "--tts-lang", "ja",
                "--tts-speaker-file", str(reference_wav()), "--output", str(out), "-ngl", "99", "--seed", str(seed),
            ]
            started = time.perf_counter()
            result = subprocess.run(args, capture_output=True, text=True, errors="replace")
            elapsed = time.perf_counter() - started
            with open(self.log, "a") as log:
                log.write(f"$ {' '.join(args)}\n{result.stdout}\n{result.stderr}\n")
            if result.returncode != 0 or not out.exists():
                raise RuntimeError(f"llama-tts failed ({result.returncode}); see {self.log}")
            audio, rate = sf.read(out, dtype="float32")
        assert rate == SAMPLE_RATE, rate
        audio = audio if audio.ndim == 1 else audio.mean(axis=1)
        return Synthesis(audio, elapsed, [(elapsed, len(audio) / SAMPLE_RATE)], frames=round(len(audio) / 1920))

    def memory(self) -> dict:
        return {}

    def close(self) -> None:
        pass
