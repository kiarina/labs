#!/usr/bin/env python3
"""Owner conversation: per assistant turn, the echo component (projection on the
played reference) in the mic and in the post/pre AEC outputs. No transcripts."""
import argparse, json
from pathlib import Path
import numpy as np
p = argparse.ArgumentParser(); p.add_argument('trial', type=Path); p.add_argument('output', type=Path); a = p.parse_args()
d = a.trial; r = json.loads((d / 'report.json').read_text())
L = lambda n: np.fromfile(d / f'{n}.pcm', '<i2').astype(np.float64)
raw, post, pre, ref = L('raw'), L('post'), L('pre'), L('reference')
cm = np.fromfile(d / 'clock_map.i64', '<i8').reshape(-1, 2); m = cm[cm[:, 1] > 48000]
clag = float(np.median(m[:, 0] - m[:, 1]))
db = lambda v: None if len(v) == 0 else float(10 * np.log10(np.mean(v * v) / 32768 ** 2 + 1e-12))
win = slice(48000 * 8, 48000 * 60)
extra = max(range(0, 12000, 48), key=lambda x: np.dot(raw[win], ref[int(48000 * 8 - clag - x):int(48000 * 8 - clag - x) + 48000 * 52]))
lag = clag + extra
pts = [(e['clockMs'], e['rawSample']) for e in r['events']]
(c0, s0), (c1, s1) = pts[0], pts[-1]
to_s = lambda ms: int(s0 + (ms - c0) * (s1 - s0) / (c1 - c0))
turns, opened = [], None
for e in r['events']:
    if e['kind'] == 'turn.created' and e['role'] == 'assistant': opened = e
    if e['kind'] == 'turn.done' and e['role'] == 'assistant' and opened:
        s, t = to_s(opened['clockMs']), to_s(e['clockMs'])
        blocks = [k for k in range(s, t - 480, 480) if 0 <= k - lag < len(ref) - 480 and db(ref[int(k - lag):int(k - lag) + 480]) > -45]
        row = {'startMs': opened['clockMs'], 'endMs': e['clockMs'], 'mode': opened['mode'], 'reference': opened['send'],
               'playbackSeconds': round(len(blocks) * 480 / 48000, 2)}
        if blocks:
            idx = np.concatenate([np.arange(k, k + 480) for k in blocks]); rr = ref[(idx - lag).astype(int)]
            for name, sig in [('mic', raw), ('post', post), ('pre', pre)]:
                g = np.dot(sig[idx], rr) / np.dot(rr, rr)
                row[name] = {'levelDbfs': db(sig[idx]), 'echoComponentDbfs': db(g * rr),
                             'correlationWithPlayed': float(np.dot(sig[idx], rr) / (np.linalg.norm(sig[idx]) * np.linalg.norm(rr) + 1e-9))}
        turns.append(row); opened = None
counts = {}
for e in r['events']: counts[e['kind']] = counts.get(e['kind'], 0) + 1
res = {'session': r['session'], 'errors': r['errors'], 'elapsedMs': r['elapsedMs'], 'clockLagSamples': clag, 'acousticMs': extra / 48,
       'eventCounts': counts, 'assistantTurns': turns, 'playout': r.get('statsBeforeClose', {}).get('playout'),
       'captureStarts': r.get('captureStarts'), 'maxAudioGapMs': r.get('maxAudioGapMs'),
       'note': 'echoComponent is the least-squares projection on the played reference over playback blocks; the owner also spoke during some turns.'}
a.output.write_text(json.dumps(res, ensure_ascii=False, indent=2) + '\n')
for t in turns: print(t['startMs'], t['mode'], t['reference'], t['playbackSeconds'], {k: round(t[k]['echoComponentDbfs'], 1) for k in ['mic', 'post', 'pre'] if k in t})
