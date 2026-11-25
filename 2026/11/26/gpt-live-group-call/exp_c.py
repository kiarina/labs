"""C: 2 people and 3 Spirits in one group call, everything by voice.

usage: python exp_c.py <label> <audio|floor|text> [scenario_c.json]

- audio: every Spirit's voice goes to the device and to the other Spirits as it is generated
- floor: one Spirit at a time; speech generated while another Spirit holds the floor is queued and released after it
  (to the device and to the other Spirits). The speaker note goes out when a Spirit gets the floor.
- text:  the people still by voice, but a Spirit's voice is not relayed; what it said goes to the other Spirits
  as a `developer` note "[name] text" when its turn is done

The people's lines of scenario.json are spoken with macOS `say` (田中 = Kyoko, 佐藤 = Rocko) and go into every
Spirit's microphone track. Each Spirit's voice goes into the other Spirits' microphone tracks (nobody hears itself).
`scenario_c.json` is scenario.json with ハル→ルカ and ソラ→ノエル (ハル was heard as 春 "spring" in the first runs).
Whenever anyone (person or Spirit) starts speaking, the Spirits that hear it get "[話者メモ] 今話し始めたのは…" on
`commentary`. Pacing: a person starts a line only after no Spirit voice for 1 s (2 s after a line addressed to Spirits,
which first waits up to 15 s for a reply); 0.6 s after a line between people. The device mix goes to work/<label>-device.wav.
"""
import asyncio, json, sys

from exp_b import say
from group import Group, HERE, SR

SCN = json.loads((HERE / (sys.argv[3] if len(sys.argv) > 3 and not sys.argv[1].startswith('--') else 'scenario_c.json')).read_text())
VOICES = {'田中': 'Kyoko', '佐藤': 'Rocko'}
NAMES = [n for n, _ in SCN['spirits']]
PEOPLE = '・'.join(f'{p}さん' for p in SCN['people'])
GAP_PEOPLE, SETTLE, REPLY_TIMEOUT = 0.6, 2.0, 15.0


def prompt(me):
    friends = '・'.join(n for n in NAMES if n != me)
    return (f'あなたは「{me}」という名前の Spirit です。今、人の{PEOPLE}の 2 人と、ほかの Spirit（{friends}）と同じグループ通話にいます。'
            'ほかの Spirit の声も、人の声と同じように通話の音声で聞こえます。'
            '誰かが話し始めるたびに「[話者メモ] …」で誰の声かが知らされるので、誰が話しているかはそれで判断してください。メモには返事をしないでください。'
            f'「{me}」と呼ばれたときか、全員に聞かれたときだけ、日本語で短く（1〜2文）答えてください。'
            '人どうしの会話や、ほかの Spirit への呼びかけには口をはさまず、黙っていてください。ほかの人が話している間は話し始めないでください。'
            '委譲はしないでください。')


async def main():
    label, mode = sys.argv[1], sys.argv[2]
    clips = {l['id']: say(l['text'], VOICES[l['who']]) for l in SCN['lines']}
    g = await Group([(n, v, prompt(n)) for n, v in SCN['spirits']], relay=mode if mode != 'text' else 'text-developer', note_channel='commentary').start()
    await asyncio.sleep(2)
    for line in SCN['lines']:
        x = clips[line['id']]
        await g.quiet_audio(1.0)
        g.log('line_start', id=line['id'], who=line['who'], to=line['to'], text=line['text'])
        before = len(g.said())
        for sp in g.spirits:
            sp.note(f'[話者メモ] 今話し始めたのは{line["who"]}さんの声です。')
            sp.track.push(line['who'], x)
        g.device.add(line['who'], x)
        await asyncio.sleep(len(x) / SR)
        g.log('line_end', id=line['id'])
        if line['to']:
            end = asyncio.get_running_loop().time() + REPLY_TIMEOUT
            while len(g.said()) == before and not g.anyone_speaking() and asyncio.get_running_loop().time() < end:
                await asyncio.sleep(.05)
            await g.quiet_audio(SETTLE, 60)
        else:
            await asyncio.sleep(GAP_PEOPLE)
    await g.quiet_audio(SETTLE, 40)
    await g.stop(label)
    out = {'label': label, 'mode': mode, 'codex': g.codex, 'voices': VOICES, 'spirits': SCN['spirits'], 'prompts': {n: prompt(n) for n in NAMES},
           'timeline': g.timeline, 'events': {sp.name: [e for e in sp.events if e.get('type') != 'session.context.appended'] for sp in g.spirits}}
    (HERE / 'results').mkdir(exist_ok=True)
    (HERE / f'results/{label}.json').write_text(json.dumps(out, ensure_ascii=False, indent=1) + '\n')
    summarize(out)


def summarize(out):
    tl = out['timeline']
    starts = [e for e in tl if e['kind'] == 'line_start']
    for i, l in enumerate(starts):
        nxt = starts[i + 1]['t'] if i + 1 < len(starts) else 1e9
        spoke = [e for e in tl if e['kind'] == 'said' and l['t'] <= e['t'] < nxt]
        print(f'#{l["id"]} {l["who"]}→{"・".join(l["to"]) or "人"}: {l["text"]}')
        for e in spoke:
            print(f'    {e["t"]:6.1f} {e["spirit"]}: {e["text"]}')
    talking, overlaps = set(), 0
    for e in tl:
        if e['kind'] == 'speak_start':
            overlaps += bool(talking)
            talking.add(e['spirit'])
        elif e['kind'] == 'said':
            talking.discard(e['spirit'])
    print('speak_start while another Spirit was speaking:', overlaps)
    fl = [e for e in tl if e['kind'] == 'floor']
    if fl:
        print('floor turns:', len(fl), 'waited (s):', [e['waited'] for e in fl])


if __name__ == '__main__':
    if sys.argv[1] == '--summary':
        summarize(json.loads((HERE / f'results/{sys.argv[2]}.json').read_text()))
    else:
        asyncio.run(main())
