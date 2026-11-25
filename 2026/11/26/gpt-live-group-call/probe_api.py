"""What text inputs make one Spirit speak? (one call, checks done one after another)

1. a user turn (appendText) that is not addressed to the Spirit: does it stay silent?
2. a user turn addressed to it: does it answer?
3. session.context.append with channel 'speakable' / 'user' (not commentary): accepted? spoken?
4. a data channel `response.create`: accepted?
"""
import asyncio, json, sys
from pathlib import Path

from group import Group, HERE

PROMPT = ('あなたは「ハル」という名前の Spirit です。グループ通話にいて、人の発言は「[名前] 発言」の形の文字で届きます。'
          '「ハル」と呼ばれたときか、全員に聞かれたときだけ、日本語で短く（1文）答えてください。'
          'それ以外の発言には何も言わず、黙っていてください。')


async def main():
    g = await Group([('ハル', 'juniper', PROMPT)]).start()
    h = g.spirits[0]
    await asyncio.sleep(1.5)

    async def step(name, fn):
        g.log('step', name=name)
        n = len(g.said())
        await fn()
        await asyncio.sleep(6)
        await g.quiet(2, 15)
        print(name, '->', [e['text'] for e in g.said()[n:]], [e['event'] for e in g.timeline if e['kind'] == 'dc_error'][-1:])

    await step('user-not-addressed', lambda: h.say_to('[田中] 佐藤さん、昨日の試合見た？'))
    await step('user-addressed', lambda: h.say_to('[田中] ハル、明日の天気ってどう思う？ひとことで。'))

    async def ctx(ch):
        h.dc.send(json.dumps({'type': 'session.context.append', 'channel': ch,
                              'content': [{'type': 'input_text', 'text': '[佐藤] ハル、好きな果物をひとつ教えて。'}]}))
    await step('ctx-speakable', lambda: ctx('speakable'))
    await step('ctx-user', lambda: ctx('user'))

    async def rc():
        h.dc.send(json.dumps({'type': 'response.create'}))
    await step('response.create', rc)
    await g.stop('probe_api')
    (HERE / 'results').mkdir(exist_ok=True)
    (HERE / 'results/probe_api.json').write_text(json.dumps({'codex': g.codex, 'timeline': g.timeline}, ensure_ascii=False, indent=1) + '\n')

asyncio.run(main())
