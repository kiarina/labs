#!/usr/bin/env python3
"""Listening comparison: the same gpt-live reply converted by
(1) the app's streaming path (upstream runtime, 2 ODE steps),
(2) the streaming path with 3 steps,
(3) file-mode conversion (upstream infer_e2e, 3 steps, as labs meanvc2-japanese-os-tts).
All outputs are loudness-matched to the original and kept below full scale, so that
level/clipping does not decide the comparison. Writes 48 kHz WAVs (private)."""
import argparse, json, time
from pathlib import Path
import numpy as np
import soundfile as sf
import soxr
import torch

from stream_vc import StreamingVC, CHUNK
from server import target_audio


def segment(received: Path, seconds: float) -> np.ndarray:
    x = np.fromfile(received, '<i2').astype(np.float32) / 32768
    hop = 4800
    rms = np.array([np.sqrt(np.mean(x[i:i + hop] ** 2)) for i in range(0, len(x) - hop, hop)])
    need = int(seconds * 48000 / hop)
    best = max(range(len(rms) - need), key=lambda i: np.sum(rms[i:i + need] > 0.01))
    return x[best * hop:best * hop + int(seconds * 48000)]


def match(y48: np.ndarray, ref48: np.ndarray) -> np.ndarray:
    act = lambda v: np.sqrt(np.mean(v[np.abs(v) > 0.015] ** 2))
    y = y48 * (act(ref48) / max(act(y48), 1e-6))
    peak = np.abs(y).max()
    return y * (0.89 / peak) if peak > 0.89 else y  # keep 1 dB below full scale


def streaming(vc: StreamingVC, x16: np.ndarray, steps: int) -> np.ndarray:
    previous = vc.runner.ode_steps
    vc.runner.ode_steps = steps
    try:
        vc.reset()
        torch.manual_seed(0)
        out = [vc.process(x16[i:i + CHUNK]) for i in range(0, len(x16) - CHUNK + 1, CHUNK)]
        return np.concatenate(out)
    finally:
        vc.runner.ode_steps = previous


def main():
    p = argparse.ArgumentParser()
    p.add_argument('received', type=Path)
    p.add_argument('outdir', type=Path)
    p.add_argument('--seconds', type=float, default=12)
    p.add_argument('--target', default='asset:speaker2')
    p.add_argument('--extras', action='store_true', help='5 high band from the original, 6 six steps, 7 40ms model')
    a = p.parse_args()
    a.outdir.mkdir(parents=True, exist_ok=True)
    x48 = segment(a.received, a.seconds)
    x16 = soxr.resample(x48, 48000, 16000)
    vc = StreamingVC(threads=1)
    target = target_audio(a.target)
    vc.set_target(target)
    up = lambda y16: soxr.resample(y16, 16000, 48000)
    report = {'seconds': a.seconds, 'target': a.target, 'files': {}}
    outputs = {'1-original': x48}
    for steps in (2, 3):
        t0 = time.perf_counter()
        outputs[f'2-streaming-steps{steps}' if steps == 2 else '3-streaming-steps3'] = up(streaming(vc, x16, steps))
        report[f'streamingSteps{steps}Seconds'] = round(time.perf_counter() - t0, 2)
    if a.extras:
        from scipy.signal import butter, sosfiltfilt
        base = outputs['3-streaming-steps3']
        # Align the original to the converted voice (streaming delay) by envelopes.
        env = lambda v: np.sqrt(np.convolve(v * v, np.ones(480) / 480, 'same'))
        ex, ey = env(x48), env(base)
        m = min(len(ex), len(ey)) - 48000 // 2
        lag = max(range(0, 48000 // 2, 48), key=lambda k: float(np.dot(ex[:m], ey[k:k + m])))
        hp = sosfiltfilt(butter(8, 7000, 'highpass', fs=48000, output='sos'), x48)
        shifted = np.zeros_like(base)
        n = min(len(base) - lag, len(hp))
        shifted[lag:lag + n] = hp[:n]
        outputs['5-streaming-steps3-highband'] = match(base, x48) + shifted
        report['highbandLagMs'] = lag / 48
        t0 = time.perf_counter()
        outputs['6-streaming-steps6'] = up(streaming(vc, x16, 6))
        report['streamingSteps6Seconds'] = round(time.perf_counter() - t0, 2)
        vc40 = StreamingVC(threads=1, model='40ms', steps=3)
        vc40.set_target(target)
        vc40.reset()
        torch.manual_seed(0)
        t0 = time.perf_counter()
        outputs['7-streaming-40ms-steps3'] = up(np.concatenate([vc40.process(x16[i:i + CHUNK]) for i in range(0, len(x16) - CHUNK + 1, CHUNK)]))
        report['streaming40msSteps3Seconds'] = round(time.perf_counter() - t0, 2)
    # File mode, upstream infer_e2e as the file-mode lab.
    from meanvc2_runtime import MeanVC2
    file_vc = MeanVC2(Path(__file__).resolve().parent, threads=4)
    emb = file_vc.speaker_embedding(target)
    t0 = time.perf_counter()
    conv = file_vc.convert(x16, emb, model='120ms', steps=3, seed=0)
    report['fileSteps3Seconds'] = round(time.perf_counter() - t0, 2)
    outputs['4-file-steps3'] = up(conv[0] if isinstance(conv, tuple) else getattr(conv, 'audio', getattr(conv, 'wav', None)))
    for name, y in outputs.items():
        y = y if name in ('1-original', '5-streaming-steps3-highband') else match(y, x48)
        if name == '5-streaming-steps3-highband':
            y = y * min(1.0, 0.89 / max(float(np.abs(y).max()), 1e-6))
        path = a.outdir / f'{name}.wav'
        sf.write(path, y, 48000, subtype='PCM_16')
        report['files'][name] = {'seconds': round(len(y) / 48000, 2), 'peak': round(float(np.abs(y).max()), 3)}
    (a.outdir / 'ab.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report))


if __name__ == '__main__':
    main()
