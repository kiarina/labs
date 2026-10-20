#!/usr/bin/env python3
"""Same content, two paths: what the app actually handed to the speaker in VC
mode (reference trace) vs the offline conversion of the same received voice
(controlReference is the pre-slot voice paired in lockstep with the played one).
Writes 48 kHz WAVs at the same loudness (private)."""
import argparse, json
from pathlib import Path
import numpy as np
import soundfile as sf
import soxr
import torch

from stream_vc import StreamingVC, CHUNK
from server import target_audio
from ab import match


def main():
    p = argparse.ArgumentParser()
    p.add_argument('trial', type=Path)
    p.add_argument('outdir', type=Path)
    p.add_argument('--target', required=True)
    p.add_argument('--steps', type=int, default=3)
    p.add_argument('--seconds', type=float, default=12)
    a = p.parse_args()
    played = np.fromfile(a.trial / 'reference.pcm', '<i2').astype(np.float32) / 32768
    pre = np.fromfile(a.trial / 'controlReference.pcm', '<i2').astype(np.float32) / 32768
    n = min(len(played), len(pre))
    sec = 48000
    # VC-mode seconds: played differs from the paired pre-slot voice; speech in both.
    vc_sec = [i for i in range(n // sec) if not np.array_equal(played[i * sec:(i + 1) * sec], pre[i * sec:(i + 1) * sec])
              and np.sqrt(np.mean(pre[i * sec:(i + 1) * sec] ** 2)) > 0.01]
    need = int(a.seconds)
    start = None
    for i in vc_sec:
        if all(j in vc_sec for j in range(i, i + need)):
            start = i
            break
    if start is None:
        raise SystemExit('no continuous VC-mode speech window')
    s, e = start * sec, (start + need) * sec
    live = played[s:e]
    source = pre[s:e]
    vc = StreamingVC(threads=1, steps=a.steps)
    vc.set_target(target_audio(a.target))
    torch.manual_seed(0)
    x16 = soxr.resample(source, 48000, 16000)
    y16 = np.concatenate([vc.process(x16[i:i + CHUNK]) for i in range(0, len(x16) - CHUNK + 1, CHUNK)])
    offline = soxr.resample(y16, 16000, 48000)
    a.outdir.mkdir(parents=True, exist_ok=True)
    sf.write(a.outdir / 'A-app-played.wav', match(live.copy(), source), 48000, subtype='PCM_16')
    sf.write(a.outdir / 'B-offline-same-content.wav', match(offline, source), 48000, subtype='PCM_16')
    sf.write(a.outdir / '0-source.wav', source, 48000, subtype='PCM_16')
    info = {'windowStartSeconds': start, 'seconds': need, 'steps': a.steps,
            'livePeak': float(np.abs(live).max()), 'liveNearFull': int(np.sum(np.abs(live) > 0.97))}
    (a.outdir / 'info.json').write_text(json.dumps(info, indent=2) + '\n')
    print(json.dumps(info))


if __name__ == '__main__':
    main()
