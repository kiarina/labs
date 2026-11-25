"""Start a Codex realtime (gpt-live) call with a given model and check what the backend used.

Talks to `codex app-server` over stdio, opens the WebRTC call with aiortc (silent mic),
sends one short user text, and records the session events seen on the `oai-events`
data channel (the model name the backend reports) and the assistant transcript.
Uses the ChatGPT login of the Codex CLI; no API key.
"""
import asyncio, json, os, sys, time
from pathlib import Path

from aiortc import RTCPeerConnection, RTCConfiguration, RTCSessionDescription
from aiortc.mediastreams import AudioStreamTrack

TEXT = '「はい」とだけ短く答えてください。'


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


async def run(label, cmd, model):
    env = dict(os.environ)
    env.pop('OPENAI_API_KEY', None)
    version = (await (await asyncio.create_subprocess_exec(*cmd, '--version', stdout=asyncio.subprocess.PIPE, env=env)).communicate())[0].decode().strip()
    out = {'label': label, 'codex': version, 'requested_model': model}
    dc_events = []
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    pc.addTrack(AudioStreamTrack())
    dc = pc.createDataChannel('oai-events')
    dc.on('message', lambda m: dc_events.append(json.loads(m)))
    await pc.setLocalDescription(await pc.createOffer())
    s = await AppServer(cmd, env).start()
    t0 = time.monotonic()
    try:
        tid = (await s.call('thread/start', {'ephemeral': True, 'cwd': str(Path('.').resolve()),
                                             'approvalPolicy': 'never', 'sandbox': 'read-only'}))['thread']['id']
        params = {'threadId': tid, 'version': 'v3', 'outputModality': 'audio', 'includeStartupContext': False,
                  'prompt': 'You are a test voice. Answer in one short Japanese word.',
                  'transport': {'type': 'webrtc', 'sdp': pc.localDescription.sdp}}
        if model:
            params['model'] = model
        await s.call('thread/realtime/start', params)
        e = await s.until(lambda x: x.get('method') in ['thread/realtime/sdp', 'thread/realtime/error'], 30)
        if not e or e['method'] != 'thread/realtime/sdp':
            out['error'] = e['params'] if e else 'no sdp in 30 s'
            return out
        await pc.setRemoteDescription(RTCSessionDescription(sdp=e['params']['sdp'], type='answer'))
        end = time.monotonic() + 15
        while dc.readyState != 'open' and time.monotonic() < end:
            await asyncio.sleep(.05)
        out['connected_s'] = round(time.monotonic() - t0, 2)
        await asyncio.sleep(1)
        sent = time.monotonic()
        await s.call('thread/realtime/appendText', {'threadId': tid, 'role': 'user', 'text': TEXT})
        done = await s.until(lambda x: x.get('method') == 'thread/realtime/transcript/done' and x['t'] > sent
                             and x['params'].get('role') != 'user', 20)
        if done:
            out['reply'] = done['params']
            out['reply_s'] = round(done['t'] - sent, 2)
        err = [x['params'] for x in s.events if x.get('method') == 'thread/realtime/error']
        if err:
            out['errors'] = err
        await s.call('thread/realtime/stop', {'threadId': tid})
    finally:
        await s.close()
        await pc.close()
    sess = [x for x in dc_events if x.get('type', '').startswith('session.')]
    out['session_started'] = next((x for x in dc_events if x.get('type') == 'session.started'), None)
    out['dc_event_types'] = sorted({x.get('type') for x in dc_events})
    return out


async def main():
    label, model = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else None)
    cmd = os.environ.get('CODEX', 'codex').split()
    r = await run(label, cmd, model)
    print(json.dumps(r, ensure_ascii=False, indent=1))
    Path('results').mkdir(exist_ok=True)
    Path(f'results/{label}.json').write_text(json.dumps(r, ensure_ascii=False, indent=1) + '\n')

asyncio.run(main())
