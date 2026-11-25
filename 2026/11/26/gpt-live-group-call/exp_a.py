"""A: the users' speech reaches 3 Spirits only as text with the speaker's name. Who answers?

usage: python exp_a.py <label> <router-commentary|router-developer|router-mixed>

On v3, `thread/realtime/appendText` drops the role and is sent as `session.context.append` with no channel,
which the backend treats as `speakable` (Codex 0.172.0, codex-api methods_common.rs). There is no "the user said"
text input; text is only ever context on one of three channels: speakable / commentary / developer.

- router-commentary: every line goes to the Spirits it is not addressed to as a `commentary` note; the Spirits it
                     is addressed to (the scenario's `to`, i.e. a perfect router) get it as a `speakable` cue, one
                     after another. What a Spirit says goes to the others as a `commentary` note.
- router-developer:  same routing, but the notes go on `developer` and the addressed Spirits get the line through
                     appendText (= `speakable` with no channel).
- router-mixed:      the Spirits a line is addressed to get it on `commentary` (when it is their turn); the others
                     get it on `developer`. What a Spirit says goes to the others on `developer`.
The users' lines are given as text at once (no speech recognition delay in this lab).
"""
import asyncio, json, sys

from group import Group, HERE

SCN = json.loads((HERE / 'scenario.json').read_text())
PEOPLE = '・'.join(f'{p}さん' for p in SCN['people'])
ALL = [n for n, _ in SCN['spirits']]


def prompt(me):
    friends = '・'.join(n for n in ALL if n != me)
    return (f'あなたは「{me}」という名前の Spirit です。今、{PEOPLE}の 2 人と、ほかの Spirit（{friends}）と同じグループ通話にいます。'
            '人の発言は「[名前] 発言」の形の文字で届きます。ほかの Spirit の発言も「[名前] 発言」の文字で届きます。'
            f'「{me}」と呼ばれたときか、全員に聞かれたときだけ、日本語で短く（1〜2文）答えてください。'
            '人どうしの会話や、ほかの Spirit への呼びかけには何も言わず、黙っていてください。委譲はしないでください。')


def cue(sp, text):
    sp.dc.send(json.dumps({'type': 'session.context.append', 'channel': 'speakable', 'content': [{'type': 'input_text', 'text': text}]}))
    sp.log('speakable', text=text)


async def main():
    label, mode = sys.argv[1], sys.argv[2]
    ch = 'commentary' if mode == 'router-commentary' else 'developer'
    g = await Group([(n, v, prompt(n)) for n, v in SCN['spirits']], relay=f'text-{ch}').start()
    await asyncio.sleep(1.5)
    for line in SCN['lines']:
        text = f'[{line["who"]}] {line["text"]}'
        g.log('line', id=line['id'], who=line['who'], to=line['to'], text=line['text'])
        targets = [g.by_name[n] for n in line['to']]
        for s in g.spirits:
            if mode == 'router-mixed' and s in targets:
                continue
            if not targets or s is not targets[0]:
                s.note(text, ch)
        nxt = f'[進行] 続けて、あなたの番です。直前の{line["who"]}さんの発言に答えてください。'
        for i, s in enumerate(targets):
            if mode == 'router-mixed':
                s.note(text, 'commentary')
            elif mode == 'router-commentary':
                cue(s, text if i == 0 else nxt)
            else:
                await s.say_to(text if i == 0 else nxt)
            await asyncio.sleep(1)
            await g.quiet(1.5, 25)
        await asyncio.sleep(1)
        await g.quiet(2.0, 25)
    await g.quiet(2.0, 20)
    await g.stop(label)
    out = {'label': label, 'mode': mode, 'codex': g.codex, 'prompts': {n: prompt(n) for n in ALL}, 'timeline': g.timeline,
           'events': {sp.name: [e for e in sp.events if e.get('type') != 'session.context.appended'] for sp in g.spirits}}
    (HERE / 'results').mkdir(exist_ok=True)
    (HERE / f'results/{label}.json').write_text(json.dumps(out, ensure_ascii=False, indent=1) + '\n')
    for e in g.timeline:
        if e['kind'] in ('line', 'said', 'dc_error', 'delegation'):
            print(e['t'], e['kind'], e.get('spirit', e.get('who', '')), e.get('text', e.get('event', '')))

asyncio.run(main())
