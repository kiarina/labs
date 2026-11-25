"""Which data channel carries group-chat text without making a Spirit speak?

usage: python probe_channels.py <label>

4 independent calls at once (no relay between them): 2 get the text on `commentary`, 2 on `developer`.
Each gets: two user lines not addressed to it, then another Spirit's remark, then (on `speakable`)
a question that needs that remark. Logs whether it spoke before the question, and what it answered.
"""
import asyncio, json, sys

from group import Group, HERE

PROMPT = ('あなたは「ハル」という名前の Spirit です。田中さん・佐藤さんの 2 人と、ほかの Spirit のミオと同じグループ通話にいます。'
          '人とほかの Spirit の発言は「[名前] 発言」の形の文字で届きます。これはあなたの発言ではありません。'
          '「ハル」と呼ばれたときか、全員に聞かれたときだけ、日本語で短く（1文）答えてください。それ以外は黙っていてください。委譲はしないでください。')
STEPS = ['[田中] 佐藤さん、今度の連休どこか行く？', '[佐藤] 温泉かキャンプで迷ってるんだよね。', '[ミオ] 私はキャンプ派かな、焚き火がしたいから。']
QUESTION = '[佐藤] ハル、ミオは温泉とキャンプのどっち派だって？理由も。'


async def main():
    label = sys.argv[1]
    chans = ['commentary', 'commentary', 'developer', 'developer']
    g = await Group([(f'{c}-{i}', 'juniper', PROMPT) for i, c in enumerate(chans)]).start()
    await asyncio.sleep(1.5)

    def send(sp, ch, text):
        sp.dc.send(json.dumps({'type': 'session.context.append', 'channel': ch, 'content': [{'type': 'input_text', 'text': text}]}))
        sp.log(f'ctx_{ch}', text=text)

    for text in STEPS:
        for sp, ch in zip(g.spirits, chans):
            send(sp, ch, text)
        await asyncio.sleep(6)
    g.log('question')
    for sp in g.spirits:
        send(sp, 'speakable', QUESTION)
    await asyncio.sleep(3)
    await g.quiet(2, 25)
    await g.stop(label)
    (HERE / f'results/{label}.json').write_text(json.dumps({'label': label, 'codex': g.codex, 'prompt': PROMPT, 'timeline': g.timeline}, ensure_ascii=False, indent=1) + '\n')
    q = next(e['t'] for e in g.timeline if e['kind'] == 'question')
    for sp in g.spirits:
        said = [e for e in g.timeline if e['kind'] == 'said' and e['spirit'] == sp.name]
        print(sp.name, 'before:', [e['text'] for e in said if e['t'] < q], '| answer:', [e['text'] for e in said if e['t'] >= q])

asyncio.run(main())
