"""Per line: what the assistant said, delegations and their answers, camera notes. Works on results/*.json."""
import json, sys
from pathlib import Path

SCN = json.loads(Path(__file__).with_name('scenario.json').read_text())
LINES = {l['id']: l for l in SCN['lines']}


def rows(path):
    d = json.loads(Path(path).read_text())
    tl, ev = d['timeline'], d['events']
    starts = [x for x in tl if x['kind'] == 'line_start']
    end = max([x['t'] for x in tl] + [x['_t'] for x in ev]) + 1
    out = []
    for k, st in enumerate(starts):
        t0, t1 = st['t'], (starts[k + 1]['t'] if k + 1 < len(starts) else end)
        inside = lambda t: t0 <= t < t1
        said = [x['turn']['transcript'] for x in ev if x['type'] == 'turn.done' and x['turn']['role'] == 'assistant' and inside(x['_t'])]
        dele = [(x['ask'], x['text'], x['seconds']) for x in tl if x['kind'] == 'delegation_reply' and inside(x['t'])]
        cams = [x['text'] for x in tl if x['kind'] == 'camera_note' and inside(x['t'])]
        notes = [x.get('who') for x in tl if x['kind'] == 'note' and inside(x['t'])]
        out.append({'line': LINES[st['id']], 'said': said, 'delegations': dele, 'camera': cams, 'notes': notes, 't': t0})
    return d, out


if __name__ == '__main__':
    for p in sys.argv[1:]:
        d, rs = rows(p)
        print(f"## {d['label']} ({d['mode']})")
        for r in rs:
            l = r['line']
            if l['to'] != 'ai' and not r['said']:
                continue
            print(f"  {l['id']:>2} {l['who']} {l.get('probe', '') or ('→AI' if l['to'] == 'ai' else '(人どうし)')} {l['text']}  notes={r['notes']}")
            for c in r['camera']:
                print(f'       cam: {c[:90]}')
            for a, t, s in r['delegations']:
                print(f'       委譲({s}s): {t}')
            print(f"       AI: {' / '.join(r['said']) or '（返事なし）'}")
            if l.get('expect'):
                print(f"       正解: {l['expect']}")
