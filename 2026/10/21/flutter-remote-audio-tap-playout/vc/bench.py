#!/usr/bin/env python3
"""Can streaming MeanVC2 keep up on this CPU? Feeds 160 ms chunks of a source
voice in real-time order (no sleeping) and records per-chunk processing time,
the first-output latency (input buffered + processing) and the output length.

Source: speaker 1, target reference: speaker 2 of the shared conversation asset
(same split as labs 2026/07/19/meanvc-streaming-apple-silicon).
"""
import argparse, json, platform, time
from pathlib import Path
import numpy as np
import soundfile as sf
import librosa
import torch

from stream_vc import StreamingVC, CHUNK

ROOT = Path(__file__).resolve().parents[1]
SOURCE = [(0.000, 1.851), (4.737, 7.317), (9.677, 11.834)]
TARGET = [(1.851, 4.737), (7.317, 9.677), (11.834, 14.171)]


def asset():
    path = ROOT.parents[3] / 'tests/assets/mp3/conversation_2speaker_14s_16k.mp3'
    audio, _ = librosa.load(path, sr=16000, mono=True)
    cut = lambda spans: np.concatenate([audio[int(a * 16000):int(b * 16000)] for a, b in spans])
    return cut(SOURCE), cut(TARGET)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--threads', type=int, nargs='+', default=[1, 2, 4])
    p.add_argument('--model', default='120ms')
    p.add_argument('--steps', type=int, default=2)
    p.add_argument('--trials', type=int, default=3)
    p.add_argument('--output', type=Path)
    p.add_argument('--wav', type=Path, help='write the last converted trial (private)')
    a = p.parse_args()
    source, target = asset()
    results = {'machine': platform.machine(), 'system': platform.system(), 'processor': platform.processor(),
               'torch': torch.__version__, 'model': a.model, 'steps': a.steps, 'chunkMs': CHUNK / 16, 'sourceSeconds': len(source) / 16000,
               'runs': []}
    for threads in a.threads:
        vc = StreamingVC(threads=threads, model=a.model, steps=a.steps)
        emb_s = vc.set_target(target)
        for _ in range(3):  # warm-up as upstream realtime mode
            vc.process(np.zeros(CHUNK, np.float32))
        times, first = [], []
        out = None
        for trial in range(a.trials):
            vc.reset()
            torch.manual_seed(20261020 + trial)
            parts, per = [], []
            fed = 0
            first_out = None
            for start in range(0, len(source), CHUNK):
                chunk = source[start:start + CHUNK]
                if len(chunk) < CHUNK:
                    chunk = np.pad(chunk, (0, CHUNK - len(chunk)))
                t0 = time.perf_counter()
                y = vc.process(chunk)
                dt = time.perf_counter() - t0
                fed += CHUNK
                per.append(dt * 1000)
                if len(y) and first_out is None:
                    # Input time buffered until this chunk + processing of it.
                    first_out = fed / 16 + dt * 1000
                parts.append(y)
            times += per
            first.append(first_out)
            out = np.concatenate(parts)
        arr = np.array(times)
        row = {'threads': threads, 'loadSeconds': round(vc.load_seconds, 2), 'targetEmbeddingSeconds': round(emb_s, 3),
               'chunks': len(arr), 'p50Ms': float(np.percentile(arr, 50)), 'p95Ms': float(np.percentile(arr, 95)),
               'p99Ms': float(np.percentile(arr, 99)), 'maxMs': float(arr.max()),
               'deadlineMisses': int(np.sum(arr > CHUNK / 16)), 'realTimeFactor': float(arr.mean() / (CHUNK / 16)),
               'firstOutputMs': first, 'outputSeconds': len(out) / 16000}
        results['runs'].append(row)
        print(json.dumps(row), flush=True)
        if a.wav:
            sf.write(a.wav, out, 16000)
    if a.output:
        a.output.write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__':
    main()
