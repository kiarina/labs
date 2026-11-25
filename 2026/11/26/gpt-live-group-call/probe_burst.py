"""Does a quick burst of `commentary` notes make a Spirit speak on its own?

usage: python probe_burst.py <label> <gap seconds> [variant ...]

Independent calls (named ミオ, no relay), one per variant (default: commentary-plain x4). Each gets lines 1-3 of
scenario.json, `gap` s apart. Line 3 is a question addressed to ハル, not to them. Logs whether they speak in the next 15 s.
variant = <commentary|developer>-<plain|framed>; framed = 「[会話の記録・あなた宛てではない] 田中さんの発言（ハル宛て）：「…」」
"""
import asyncio, json, sys

from group import Group, HERE

SCN = json.loads((HERE / 'scenario.json').read_text())
PROMPT = ('あなたは「ミオ」という名前の Spirit です。今、田中さん・佐藤さんの 2 人と、ほかの Spirit（ハル・ソラ）と同じグループ通話にいます。'
          '人の発言は「[名前] 発言」の形の文字で届きます。ほかの Spirit の発言も「[名前] 発言」の文字で届きます。'
          '「ミオ」と呼ばれたときか、全員に聞かれたときだけ、日本語で短く（1〜2文）答えてください。'
          '人どうしの会話や、ほかの Spirit への呼びかけには何も言わず、黙っていてください。委譲はしないでください。')


async def main():
    label, gap = sys.argv[1], float(sys.argv[2])
    variants = sys.argv[3:] or ['commentary-plain'] * 4
    g = await Group([(f'{v}-{i}', 'himari', PROMPT) for i, v in enumerate(variants)]).start()
    await asyncio.sleep(1.5)
    for line in SCN['lines'][:3]:
        for sp, v in zip(g.spirits, variants):
            ch, form = v.split('-')
            to = '・'.join(line['to']) or '人どうし'
            text = (f'[{line["who"]}] {line["text"]}' if form == 'plain'
                    else f'[会話の記録・あなた宛てではない] {line["who"]}さんの発言（{to}宛て）：「{line["text"]}」')
            sp.dc.send(json.dumps({'type': 'session.context.append', 'channel': ch, 'content': [{'type': 'input_text', 'text': text}]}))
            sp.log(f'ctx_{ch}', text=text)
        await asyncio.sleep(gap)
    await asyncio.sleep(15)
    await g.quiet(2, 20)
    await g.stop(label)
    (HERE / f'results/{label}.json').write_text(json.dumps({'label': label, 'gap': gap, 'variants': variants, 'codex': g.codex, 'prompt': PROMPT, 'timeline': g.timeline}, ensure_ascii=False, indent=1) + '\n')
    for sp in g.spirits:
        print(sp.name, [e['text'] for e in g.timeline if e['kind'] == 'said' and e['spirit'] == sp.name])

asyncio.run(main())
