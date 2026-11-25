"""Hold N Codex realtime (gpt-live) calls at the same time and check that each one answers on its own.

usage: python probe.py <process|thread> <N> [label]

- process: N `codex app-server` processes, one thread and one call each
- thread:  one `codex app-server` process, N threads with one call each

All calls are started at once (silent mic, aiortc). When every call that could connect is up,
each call gets a different word to repeat, twice (two rounds), so a reply that lands on the
wrong call shows up. Uses the ChatGPT login of the Codex CLI; no API key.
Connection ids, thread ids and SDP are not saved.
"""
import asyncio, json, os, sys, time
from pathlib import Path

from aiortc import RTCPeerConnection, RTCConfiguration, RTCSessionDescription
from aiortc.mediastreams import AudioStreamTrack

WORDS = ['りんご', 'みかん', 'ぶどう', 'もも', 'すいか', 'なし', 'かき', 'いちご']
ROUNDS = 2


class AppServer:
    def __init__(self, cmd, env):
        self.cmd, self.env, self.next_id, self.waiters, self.events = cmd, env, 1, {}, []

    async def start(self):
        self.p = await asyncio.create_subprocess_exec(
            *self.cmd, 'app-server', stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.DEVNULL, env=self.env, limit=64 * 1024 * 1024)
        self.reader = asyncio.create_task(self._read())
        await self.call('initialize', {'clientInfo': {'name': 'labs-gpt-live', 'version': '0'},
                                       'capabilities': {'experimentalApi': True}})
        self._send({'method': 'initialized'})
        return self

    def _send(self, msg):
        self.p.stdin.write((json.dumps(msg) + '\n').encode())

    async def _read(self):
        while line := await self.p.stdout.readline():
            msg = json.loads(line)
            if 'id' in msg and msg['id'] in self.waiters and 'method' not in msg:
                self.waiters.pop(msg['id']).set_result(msg)
            else:
                msg['t'] = time.monotonic()
                self.events.append(msg)

    async def call(self, method, params):
        i, self.next_id = self.next_id, self.next_id + 1
        fut = asyncio.get_running_loop().create_future()
        self.waiters[i] = fut
        self._send({'id': i, 'method': method, 'params': params})
        msg = await asyncio.wait_for(fut, 30)
        if 'error' in msg:
            raise RuntimeError(f'{method}: {msg["error"]}')
        return msg['result']

    async def until(self, pred, timeout):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            for e in self.events:
                if pred(e):
                    return e
            await asyncio.sleep(.05)
        return None

    async def close(self):
        self.p.kill()
        await self.p.wait()


class Call:
    def __init__(self, idx, server):
        self.idx, self.s, self.word = idx, server, WORDS[idx]
        self.out = {'call': idx, 'word': WORDS[idx], 'rounds': []}
        self.pc = None

    def mine(self, e):
        return e.get('params', {}).get('threadId') == self.tid

    async def start(self, t0):
        try:
            self.pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
            self.pc.addTrack(AudioStreamTrack())
            self.dc = self.pc.createDataChannel('oai-events')
            self.dc_types = set()
            self.dc.on('message', lambda m: self.dc_types.add(json.loads(m).get('type')))
            await self.pc.setLocalDescription(await self.pc.createOffer())
            self.tid = (await self.s.call('thread/start', {'ephemeral': True, 'cwd': str(Path('.').resolve()),
                                                           'approvalPolicy': 'never', 'sandbox': 'read-only'}))['thread']['id']
            await self.s.call('thread/realtime/start', {
                'threadId': self.tid, 'version': 'v3', 'outputModality': 'audio', 'includeStartupContext': False,
                'prompt': 'You are a test voice. Repeat exactly the one Japanese word the user asks for, nothing else.',
                'transport': {'type': 'webrtc', 'sdp': self.pc.localDescription.sdp}})
            e = await self.s.until(lambda x: self.mine(x) and x.get('method') in
                                   ['thread/realtime/sdp', 'thread/realtime/error'], 30)
            if not e or e['method'] != 'thread/realtime/sdp':
                self.out['error'] = e['params'] if e else 'no sdp in 30 s'
                return False
            await self.pc.setRemoteDescription(RTCSessionDescription(sdp=e['params']['sdp'], type='answer'))
            end = time.monotonic() + 15
            while self.dc.readyState != 'open' and time.monotonic() < end:
                await asyncio.sleep(.05)
            if self.dc.readyState != 'open':
                self.out['error'] = 'data channel not open in 15 s'
                return False
            self.out['connected_s'] = round(time.monotonic() - t0, 2)
            return True
        except Exception as ex:
            self.out['error'] = repr(ex)
            return False

    async def ask(self):
        sent = time.monotonic()
        r = {}
        try:
            await self.s.call('thread/realtime/appendText', {'threadId': self.tid, 'role': 'user',
                                                             'text': f'「{self.word}」とだけ答えてください。'})
            done = await self.s.until(lambda x: self.mine(x) and x.get('method') == 'thread/realtime/transcript/done'
                                      and x['t'] > sent and x['params'].get('role') != 'user', 20)
            if done:
                r['reply'] = done['params']['text']
                r['reply_s'] = round(done['t'] - sent, 2)
                r['matches_word'] = self.word in r['reply']
            else:
                r['reply'] = None
        except Exception as ex:
            r['error'] = repr(ex)
        self.out['rounds'].append(r)

    async def stop(self):
        err = [x['params'] for x in self.s.events if self.mine(x) and x.get('method') == 'thread/realtime/error']
        if err:
            self.out['errors'] = err
        self.out['dc_event_types'] = sorted(t for t in self.dc_types if t)
        try:
            await self.s.call('thread/realtime/stop', {'threadId': self.tid})
        except Exception:
            pass
        if self.pc:
            await self.pc.close()


async def main():
    mode, n = sys.argv[1], int(sys.argv[2])
    label = sys.argv[3] if len(sys.argv) > 3 else f'{mode}-{n}'
    cmd = os.environ.get('CODEX', 'codex').split()
    env = dict(os.environ)
    env.pop('OPENAI_API_KEY', None)
    version = (await (await asyncio.create_subprocess_exec(*cmd, '--version', stdout=asyncio.subprocess.PIPE, env=env)).communicate())[0].decode().strip()

    servers = await asyncio.gather(*[AppServer(cmd, env).start() for _ in range(n if mode == 'process' else 1)])
    calls = [Call(i, servers[i] if mode == 'process' else servers[0]) for i in range(n)]
    t0 = time.monotonic()
    try:
        ok = await asyncio.gather(*[c.start(t0) for c in calls])
        live = [c for c, o in zip(calls, ok) if o]
        await asyncio.sleep(1)
        for _ in range(ROUNDS):
            await asyncio.gather(*[c.ask() for c in live])
        await asyncio.gather(*[c.stop() for c in calls if c.pc])
    finally:
        for s in servers:
            await s.close()

    answered = sum(1 for c in calls if c.out['rounds'] and all(r.get('matches_word') for r in c.out['rounds']))
    out = {'label': label, 'codex': version, 'mode': mode, 'calls_requested': n,
           'calls_connected': sum(ok), 'calls_answered_all_rounds_with_own_word': answered,
           'calls': [c.out for c in calls]}
    print(json.dumps(out, ensure_ascii=False, indent=1))
    Path('results').mkdir(exist_ok=True)
    Path(f'results/{label}.json').write_text(json.dumps(out, ensure_ascii=False, indent=1) + '\n')

asyncio.run(main())
