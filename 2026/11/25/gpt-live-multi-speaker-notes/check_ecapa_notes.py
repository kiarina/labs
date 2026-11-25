"""Offline: run the ecapa notes over the script with the same gaps (no call). Prints one note per line."""
import json, sys
from pathlib import Path
import numpy as np
sys.argv = ['x', 'offline', 'ecapa']
src = Path('call.py').read_text().split('async def main')[0]
ns = {'__file__': 'call.py'}; exec(src, ns)
from speaker import Ecapa, Identifier, say
SCN = ns['SCN']
ident = Identifier(Ecapa(), 0.45)
for n, v in SCN['people'].items():
    ident.enroll(n, [say(v, t, f'work/voice/enroll-{n}-{k}.wav') for k, t in enumerate(SCN['enroll'])])
got = []
notes = ns['EcapaNotes'](ident, lambda who, sc, at: got.append((round(at / 16000, 2), who, {k: round(v, 2) for k, v in sc.items()})))
pos, starts = 0, []
for l in SCN['lines']:
    x = say(SCN['people'][l['who']], l['text'], f'work/voice/{l["id"]:02d}-{l["who"]}.wav')
    x = np.concatenate([x, np.zeros(int(16000 * 0.6), np.float32)])
    starts.append((round(pos / 16000, 2), l['who']))
    for i in range(0, len(x), 320):
        notes.feed(x[i:i + 320], pos + i)
    pos += len(x)
print(len(starts), 'lines', len(got), 'notes')
for k, (s0, truth) in enumerate(starts):
    s1 = starts[k + 1][0] if k + 1 < len(starts) else 1e9
    mine = [g for g in got if s0 <= g[0] < s1]
    print(s0, truth, '->', [(g[1], round(g[0] - s0, 2)) for g in mine])
