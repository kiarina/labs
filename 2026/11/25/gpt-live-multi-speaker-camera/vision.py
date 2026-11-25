"""Ask a Codex model about images through `codex app-server` (ChatGPT login): one ephemeral thread per question."""
import asyncio, time
from appserver import AppServer


class Vision:
    def __init__(self, env, cwd):
        self.env, self.cwd, self.s, self.lock = env, cwd, None, asyncio.Lock()

    async def start(self):
        self.s = await AppServer(['codex'], self.env).start()
        return self

    async def ask(self, model, effort, text, images, timeout=60):
        t0 = time.monotonic()
        tid = (await self.s.call('thread/start', {'ephemeral': True, 'cwd': str(self.cwd), 'approvalPolicy': 'never',
                                                  'sandbox': 'read-only', 'model': model}))['thread']['id']
        mark = len(self.s.events)
        await self.s.call('turn/start', {'threadId': tid, 'effort': effort,
                                         'input': [{'type': 'text', 'text': text}] + [{'type': 'localImage', 'path': str(p)} for p in images]})
        done = await self.s.until(lambda e: e.get('method') == 'turn/completed' and e['params'].get('threadId') == tid, timeout)
        msgs = [e['params']['item'] for e in self.s.events[mark:] if e.get('method') == 'item/completed'
                and e['params'].get('threadId') == tid and e['params']['item'].get('type') == 'agentMessage']
        return {'text': (msgs[-1].get('text') if msgs else '').strip(), 'seconds': round(time.monotonic() - t0, 2),
                'ok': bool(done) and done['params'].get('turn', {}).get('status') in (None, 'completed')}

    async def close(self):
        await self.s.close()
