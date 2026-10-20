#!/usr/bin/env python3
"""Per-phase metrics for one trial folder. Writes JSON; never publishes PCM.

raw: record input. mixed: raw + digital injection (what AEC receives).
post: AEC with the played (post-slot) reference. pre: control AEC fed the
pre-slot PCM in lockstep. reference/controlReference: the played and pre-slot
traces on the same speaker timeline.
"""
import argparse, json
from pathlib import Path
import numpy as np
from scipy.signal import correlate, correlation_lags

p = argparse.ArgumentParser()
p.add_argument('trial', type=Path)
p.add_argument('output', type=Path)
p.add_argument('--peer', type=Path, help='fake peer received PCM (what the remote hears)')
a = p.parse_args()
r = json.loads((a.trial / 'report.json').read_text())
load = lambda n: np.fromfile(a.trial / f'{n}.pcm', '<i2').astype(np.float64) if (a.trial / f'{n}.pcm').exists() else np.zeros(0)
x = {n: load(n) for n in ['raw', 'mixed', 'post', 'pre', 'injected', 'reference', 'controlReference', 'received']}

def dbfs(v):
    return None if len(v) == 0 else float(10 * np.log10(np.mean(v * v) / 32768 ** 2 + 1e-24))

def xcorr(seg, ref):
    """GCC-PHAT of seg against the whole ref trace. lagSamples = raw index - ref index
    (constant while both run on the same device clock)."""
    if len(seg) == 0 or len(ref) == 0:
        return None
    n = 1 << int(np.ceil(np.log2(len(seg) + len(ref))))
    R = np.fft.rfft(seg, n) * np.conj(np.fft.rfft(ref, n))
    c = np.fft.irfft(R / (np.abs(R) + 1e-9), n)
    c = np.concatenate([c[-(len(ref) - 1):], c[:len(seg)]])
    i = int(np.argmax(c))
    return {'gccPeak': float(c[i]), 'offsetSamples': int(i - (len(ref) - 1))}

cmap = a.trial / 'clock_map.i64'
clock_lag = None
if cmap.exists():
    m = np.fromfile(cmap, '<i8').reshape(-1, 2)
    m = m[m[:, 1] > 48000]
    if len(m):
        clock_lag = float(np.median(m[:, 0] - m[:, 1]))

def aligned(seg, start, trace):
    """Correlation of the mic with a speaker-timeline trace, searched from -250 ms to
    +600 ms around the clock-map alignment. extraMs is the acoustic/output delay."""
    if clock_lag is None or len(trace) == 0:
        return None
    best = (-2.0, 0)
    for extra in range(-12000, 28801, 48):
        j = int(start - clock_lag - extra)
        if j < 0 or j + len(seg) > len(trace):
            continue
        rr = trace[j:j + len(seg)]
        c = float(np.dot(seg, rr) / (np.linalg.norm(seg) * np.linalg.norm(rr) + 1e-9))
        best = max(best, (c, extra))
    return {'correlation': best[0], 'extraMs': best[1] / 48}

rows = []
for q in r['phases']:
    s = int(q['startSample']) + 48000  # discard the first second
    e = int(q['endSample'])
    if e - s < 48000:
        s = int(q['startSample'])
    if e - s < 24000:
        continue
    row = {k: q.get(k) for k in ['name', 'mode', 'far', 'near', 'gate', 'send']}
    row['seconds'] = round((e - s) / 48000, 2)
    for n in ['raw', 'mixed', 'post', 'pre']:
        row[f'{n}Dbfs'] = dbfs(x[n][s:e])
    if row['mixedDbfs'] is not None:
        row['postReductionDb'] = row['mixedDbfs'] - row['postDbfs']
        row['preReductionDb'] = row['mixedDbfs'] - row['preDbfs']
    if q.get('far') and not q.get('near'):
        for key, trace in [('micVsPlayed', 'reference'), ('micVsPreSlot', 'controlReference')]:
            row[key] = aligned(x['raw'][s:e], s, x[trace])
    if q.get('near'):
        near = x['injected'][s:e]
        for n in ['post', 'pre']:
            # Align for the AEC processing latency (search 0..40 ms).
            best = max(range(0, 1921, 8), key=lambda k: abs(np.dot(x[n][s + k:e + k], near)))
            row[f'{n}LatencySamples'] = best
            y = x[n][s + best:e + best]
            g = float(np.dot(y, near) / max(np.dot(near, near), 1e-9))
            row[f'{n}NearGainDb'] = float(20 * np.log10(max(abs(g), 1e-9)))
            row[f'{n}NearCorrelation'] = float(np.dot(y, near) / (np.linalg.norm(y) * np.linalg.norm(near) + 1e-9))
    st, en = q.get('start', {}), q.get('end', {})
    row['captureDuringPhase'] = {
        'rawSamples': (en.get('rawSamples') or 0) - (st.get('rawSamples') or 0),
        'cameraSourceFrames': (en.get('cameraSourceFrames') or 0) - (st.get('cameraSourceFrames') or 0),
        'sentSamples': (en.get('sentSamples') or 0) - (st.get('sentSamples') or 0),
        'videoSent': (en.get('videoSent') or 0) - (st.get('videoSent') or 0),
    }
    rows.append(row)

quiet = [r_ for r_ in rows if not r_.get('far') and not r_.get('near') and r_['name'] == 'quiet']
if quiet:
    floor = quiet[0]['rawDbfs']
    for r_ in rows:
        r_['postAboveQuietDb'] = r_['postDbfs'] - floor
        r_['preAboveQuietDb'] = r_['preDbfs'] - floor
        r_['mixedAboveQuietDb'] = r_['mixedDbfs'] - floor
peer = None
if a.peer and a.peer.exists():
    pr = np.fromfile(a.peer, '<i2').astype(np.float64)
    meta = json.loads(a.peer.with_name(a.peer.name.replace('-received.pcm', '-peer.json')).read_text())
    marks = meta['phases']
    peer = []
    for i, m in enumerate(marks):
        s = m['samples']; e = marks[i + 1]['samples'] if i + 1 < len(marks) else len(pr)
        peer.append({'phase': m['phase'], 'far': m['far'], 'receivedSamples': e - s, 'receivedDbfs': dbfs(pr[s + 24000:e]) if e - s > 48000 else dbfs(pr[s:e])})

stats = r.get('statsBeforeClose', {})
result = {
    'session': r['session'], 'kind': r['kind'], 'platform': r['platform'],
    'microphone': r.get('microphone'), 'speaker': r.get('speaker'), 'camera': r.get('camera'),
    'errors': r['errors'], 'captureStarts': r.get('captureStarts'), 'maxAudioGapMs': r.get('maxAudioGapMs'),
    'nativePlayoutReferenceDbfs': stats.get('nativePlayoutReferenceDbfs'),
    'clockMapLagSamples': clock_lag,
    'playout': stats.get('playout'), 'bridge': stats.get('bridge'),
    'phases': rows, 'peerReceived': peer,
    'caveats': [
        'Energy reduction is not ERLE against an independent echo-only reference.',
        'Single short run in one room; speaker and microphone of the same notebook.',
    ],
}
a.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
for row in rows:
    print(row['name'], row.get('mode'), 'mixed', round(row['mixedDbfs'] or 0, 1),
          'postRed', round(row.get('postReductionDb') or 0, 1), 'preRed', round(row.get('preReductionDb') or 0, 1),
          'aboveQuiet mixed/post/pre', [round(row.get(k) or 0, 1) for k in ['mixedAboveQuietDb', 'postAboveQuietDb', 'preAboveQuietDb']],
          'played', row.get('micVsPlayed'), 'preSlot', row.get('micVsPreSlot'))
print('nativePlayoutDbfs', result['nativePlayoutReferenceDbfs'], 'errors', r['errors'])
