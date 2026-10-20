#!/usr/bin/env python3
"""Per-question summary of a gpt-live-1-codex trial (synthetic questions).

For each ask window: turns and user segments recognized by the service, and what
was sent back while the application was playing the service's voice ("echo
sent"), using the capture/speaker clock map plus the acoustic delay. Only the
fixed synthetic question texts and the service's own output are published;
other recognized user text is replaced by its length.
"""
import argparse, json
from pathlib import Path
import numpy as np

p = argparse.ArgumentParser()
p.add_argument('trial', type=Path)
p.add_argument('output', type=Path)
p.add_argument('--acoustic-ms', type=float, default=None)
a = p.parse_args()
d = a.trial
r = json.loads((d / 'report.json').read_text())
L = lambda n: np.fromfile(d / f'{n}.pcm', '<i2').astype(np.float64)
raw, post, pre, ref, inj = L('raw'), L('post'), L('pre'), L('reference'), L('injected')
cm = np.fromfile(d / 'clock_map.i64', '<i8').reshape(-1, 2)
m = cm[cm[:, 1] > 48000]
clag = float(np.median(m[:, 0] - m[:, 1]))
db0 = lambda v: float(10 * np.log10(np.mean(v * v) / 32768 ** 2 + 1e-12))
# Acoustic/output delay: maximize the mic projection on the played trace over
# the service voice, unless --acoustic-ms is given.
if a.acoustic_ms is None:
    cand = [k for k in range(48000 * 5, len(raw) - 48000 * 2, 480)
            if 0 <= k - clag < len(ref) - 480 and db0(ref[int(k - clag):int(k - clag) + 480]) > -45][:3000]
    idx0 = np.concatenate([np.arange(k, k + 480) for k in cand])
    def score(x):
        j = (idx0 - clag - x).astype(int)
        ok = (j >= 0) & (j < len(ref))
        return abs(np.dot(raw[idx0[ok]], ref[j[ok]])) / (np.linalg.norm(ref[j[ok]]) + 1e-9)
    a.acoustic_ms = max(range(0, 19201, 48), key=score) / 48
lag = clag + a.acoustic_ms * 48
pts = [(t['clockMs'], t['rawSample']) for t in r['timeline']]
(c0, s0), (c1, s1) = pts[0], pts[-1]
to_sample = lambda ms: int(s0 + (ms - c0) * (s1 - s0) / (c1 - c0))
db = lambda v: None if len(v) == 0 else float(10 * np.log10(np.mean(v * v) / 32768 ** 2 + 1e-12))
questions = {k: v['text'] for k, v in json.loads(Path(__file__).resolve().parents[1].joinpath('results/questions.json').read_text())['questions'].items()}

# User segments from cumulative transcripts.
segments, last = [], ''
for t in r['transcripts']:
    if t['who'] == 'user' and t['text'] != last:
        segments.append({'clockMs': t['clockMs'], 'text': t['text'][len(last):]})
        last = t['text']
voice_text = ''.join(t['text'] for t in r['transcripts'][-1:] if t['who'] == 'voice') or \
    next((t['text'] for t in reversed(r['transcripts']) if t['who'] == 'voice'), '')

asks = []
marks = [t for t in r['timeline'] if t['stage'].startswith('ask-')]
for i, mark in enumerate(marks):
    begin = mark['clockMs']
    end = marks[i + 1]['clockMs'] if i + 1 < len(marks) else r['elapsedMs']
    q = mark['stage'][4:]
    phase = next(ph for ph in r['phases'] if ph['name'] == mark['stage'])
    turns = [e for e in r['events'] if begin <= e['clockMs'] < end and e['kind'] in ('turn.created', 'turn.done')]
    users = [e for e in turns if e['kind'] == 'turn.created' and e['role'] == 'user']
    assistants = [e for e in turns if e['kind'] == 'turn.created' and e['role'] == 'assistant']
    text = ''.join(s['text'] for s in segments if begin <= s['clockMs'] < end)
    qtext = questions[q].rstrip('。')
    extra = text.replace('、', '').replace('。', '')
    for part in qtext.replace('、', ''):
        extra = extra.replace(part, '', 1)
    # Echo sent: blocks where our speaker was playing the service voice.
    s, e = to_sample(begin), to_sample(end)
    sent = pre if phase['send'] == 'pre' else post
    playing, quiet = [], []
    for k in range(s, min(e, len(raw)) - 480, 480):
        j = int(k - lag)
        if 0 <= j < len(ref) - 480 and not np.any(inj[k:k + 480]):
            level = db(ref[j:j + 480])
            (playing if level > -45 else quiet if level < -80 else []).append(k)
    idx = np.concatenate([np.arange(k, k + 480) for k in playing]) if playing else np.array([], int)
    echo = {}
    if len(idx):
        rr = ref[(idx - lag).astype(int)]
        for name, sig in [('mic', raw), ('post', post), ('pre', pre)]:
            g = np.dot(sig[idx], rr) / np.dot(rr, rr)
            echo[name] = db(g * rr)
    qidx = np.concatenate([np.arange(k, k + 480) for k in quiet]) if quiet else np.array([], int)
    asks.append({
        'question': q, 'questionText': questions[q], 'mode': phase['mode'], 'sent': phase['send'],
        'userTurns': len(users), 'assistantTurns': len(assistants),
        # Recognized user text is not published (the room was not controlled).
        'recognizedExtraCharacters': len(extra.strip()),
        'serviceVoicePlayingSeconds': round(len(idx) / 48000, 1),
        'duringPlayback': {'micDbfs': db(raw[idx]), 'sentDbfs': db(sent[idx]),
                           'postDbfs': db(post[idx]), 'preDbfs': db(pre[idx])},
        'echoComponentDbfs': echo,
        'whilePlayoutSilent': {'micDbfs': db(raw[qidx]), 'sentDbfs': db(sent[qidx])},
    })
result = {
    'session': r['session'], 'errors': r['errors'], 'microphone': r.get('microphone'), 'speaker': r.get('speaker'),
    'clockLagSamples': lag, 'acousticMs': a.acoustic_ms,
    'eventCounts': {k: sum(1 for e in r['events'] if e['kind'] == k) for k in sorted({e['kind'] for e in r['events']})},
    'asks': asks, 'serviceOutputCharacters': len(voice_text),
    'playout': r.get('statsBeforeClose', {}).get('playout'),
    'captureStarts': r.get('captureStarts'), 'maxAudioGapMs': r.get('maxAudioGapMs'),
}
a.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
for x in asks:
    print(x['question'], x['mode'], x['sent'], 'user', x['userTurns'], 'assistant', x['assistantTurns'], 'extraChars', x['recognizedExtraCharacters'],
          'playing', x['serviceVoicePlayingSeconds'], {k: round(v, 1) for k, v in x['echoComponentDbfs'].items()})
