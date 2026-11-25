"""Lay out each run: what the assistant said after each line, interjections into people-to-people talk, notes."""
import json, sys
from pathlib import Path

SCN = json.loads(Path('scenario.json').read_text())
LINES = {l['id']: l for l in SCN['lines']}


def run(path):
    d = json.loads(Path(path).read_text())
    tl, ev = d['timeline'], d['events']
    starts = [x for x in tl if x['kind'] == 'line_start']
    stop = max(x['_t'] for x in ev) + 1
    said = [x for x in ev if x['type'] == 'turn.done' and x['turn']['role'] == 'assistant']
    created = {x['turn']['id']: x['_t'] for x in ev if x['type'] == 'turn.created'}
    rows = []
    for k, st in enumerate(starts):
        t0, t1 = st['t'], (starts[k + 1]['t'] if k + 1 < len(starts) else stop)
        mine = [x['turn']['transcript'] for x in said if t0 <= created.get(x['turn']['id'], x['_t']) < t1]
        line = LINES[st['id']]
        notes = [(x['who'], x['by']) for x in tl if x['kind'] == 'note' and t0 <= x['t'] < t1]
        rows.append({'id': line['id'], 'who': line['who'], 'to': line['to'], 'probe': line.get('probe'), 'expect': line.get('expect'),
                     'assistant': mine, 'notes': notes})
    interject = [r for r in rows if r['to'] == 'people' and r['assistant']]
    wrong_notes = [r for r in rows if r['notes'] and r['notes'][-1][0] != r['who']]
    return d['label'], d['mode'], rows, interject, [x for x in tl if x['kind'] == 'delegation'], wrong_notes


if __name__ == '__main__':
    for p in sys.argv[1:]:
        label, mode, rows, interject, deleg, wrong = run(p)
        print(f'## {label} ({mode})  interjections={len(interject)} delegations={len(deleg)} wrong_final_notes={len(wrong)}')
        for r in rows:
            tag = r['probe'] or ('→AI' if r['to'] == 'ai' else '')
            print(f"  {r['id']:>2} {r['who']} {tag:5} notes={r['notes']}")
            for a in r['assistant']:
                print(f'       AI: {a}')
            if r['expect']:
                print(f"       expect: {r['expect']}")
