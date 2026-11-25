"""Count, per line of an exp_c run, which Spirits said something substantial (more than 8 characters
after removing うん/うんうん/おー backchannels) before the next line started.

usage: python summarize_c.py results/c-*.json
"""
import json, re, sys

for path in sys.argv[1:]:
    d = json.load(open(path))
    tl = d['timeline']
    starts = [e for e in tl if e['kind'] == 'line_start']
    addressed_ok = addressed = 0
    extra = people_interject = backchannels = 0
    for i, l in enumerate(starts):
        nxt = starts[i + 1]['t'] if i + 1 < len(starts) else 1e9
        said = [e for e in tl if e['kind'] == 'said' and l['t'] <= e['t'] < nxt]
        talk = {}
        for e in said:
            rest = re.sub(r'(うん|おー|ん|[、。!?！？\s])', '', e['text'] or '')
            if len(rest) > 8:
                talk.setdefault(e['spirit'], []).append(e['text'])
            else:
                backchannels += 1
        if l['to']:
            addressed += len(l['to'])
            addressed_ok += sum(1 for n in l['to'] if n in talk)
            extra += sum(1 for n in talk if n not in l['to'])
        else:
            people_interject += len(talk)
    dur = max(e['t'] for e in tl)
    print(f"{d['label']:12} mode={d.get('mode', 'audio'):6} addressed answered {addressed_ok}/{addressed}  "
          f"not-addressed Spirits answering an addressed line {extra}  Spirits talking into people's lines {people_interject}  "
          f"backchannels {backchannels}  length {dur:.0f} s")
