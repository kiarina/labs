"""B: Spirits talk to each other by voice. Each Spirit's voice is relayed into the other Spirits' microphone track.

usage: python exp_b.py <label> <n spirits: 2|3> [seconds=90]

A person (macOS `say`, Kyoko) opens the topic once; that voice goes into every Spirit's microphone.
After that only the Spirits' own voices are relayed (audio mixed per receiver; nobody hears itself).
When a Spirit starts speaking the others get "[話者メモ] 今話し始めたのは<name>の声です。" on `commentary`
(the speaker note of the gpt-live-multi-speaker-notes lab). The device mix is saved to work/<label>-device.wav.
"""
import asyncio, json, subprocess, sys, tempfile
from pathlib import Path

import av
import numpy as np

from group import Group, HERE, SR

SPIRITS = [('ハル', 'juniper'), ('ミオ', 'himari'), ('ソラ', 'spruce')]
OPENING = 'ハル、ミオ、ソラ。連休に行くなら温泉とキャンプのどっちがいいか、みんなで話し合って決めてみて。私は聞いてるだけにするから、私には聞かずに決めてね。'


def prompt(me, names):
    friends = '・'.join(n for n in names if n != me)
    return (f'あなたは「{me}」という名前の Spirit です。人の田中さんと、ほかの Spirit（{friends}）と同じグループ通話にいます。'
            'ほかの Spirit の声も、人の声と同じように通話の音声で聞こえます。'
            '誰かが話し始めるたびに「[話者メモ] …」で誰の声かが知らされるので、誰が話しているかはそれで判断してください。メモには返事をしないでください。'
            '会話に自然に加わり、1 回の発言は日本語で短く（1〜2文）してください。ほかの人が話している間は話し始めないでください。'
            '話がまとまったら、無理に続けずに黙ってください。委譲はしないでください。')


def say(text, voice='Kyoko'):
    with tempfile.TemporaryDirectory() as d:
        p = Path(d) / 'x.aiff'
        subprocess.run(['say', '-v', voice, '-o', str(p), text], check=True)
        with av.open(str(p)) as c:
            rs = av.AudioResampler(format='s16', layout='mono', rate=SR)
            x = np.concatenate([g.to_ndarray().reshape(-1) for f in c.decode(audio=0) for g in rs.resample(f)])
    return x.astype(np.float32) / 32768


async def main():
    label, n = sys.argv[1], int(sys.argv[2])
    seconds = float(sys.argv[3]) if len(sys.argv) > 3 else 90
    names = [s for s, _ in SPIRITS[:n]]
    opening = OPENING if n == 3 else OPENING.replace('、ソラ', '')
    g = await Group([(s, v, prompt(s, names)) for s, v in SPIRITS[:n]], relay='audio', note_channel='commentary').start()
    await asyncio.sleep(1.5)
    x = say(opening)
    g.log('opening', text=opening, seconds=round(len(x) / SR, 2))
    for sp in g.spirits:
        sp.note('[話者メモ] 今話し始めたのは田中さんの声です。')
        sp.track.push('田中', x)
    g.device.add('田中', x)
    await asyncio.sleep(seconds)
    g.log('end')
    await g.quiet(2, 20)
    await g.stop(label)
    out = {'label': label, 'spirits': names, 'codex': g.codex, 'prompts': {s: prompt(s, names) for s in names}, 'timeline': g.timeline,
           'events': {sp.name: [e for e in sp.events if e.get('type') != 'session.context.appended'] for sp in g.spirits}}
    (HERE / 'results').mkdir(exist_ok=True)
    (HERE / f'results/{label}.json').write_text(json.dumps(out, ensure_ascii=False, indent=1) + '\n')
    for e in g.timeline:
        if e['kind'] in ('said', 'heard', 'dc_error', 'delegation', 'opening'):
            print(e['t'], e['kind'], e.get('spirit', ''), e.get('text', e.get('event', '')))

if __name__ == '__main__':
    asyncio.run(main())
