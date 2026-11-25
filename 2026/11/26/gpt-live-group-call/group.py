"""Several gpt-live calls ("Spirits") in one group, started through one `codex app-server` (one thread each).

- Every Spirit has its own WebRTC call (aiortc). Its microphone track is a mixer: other Spirits' voices can be
  relayed into it (`relay='audio'`), otherwise it sends silence. The user's microphone is never sent.
- What a Spirit says is collected per Spirit (16 kHz) and also mixed into one "device" track, which is what
  the device of the user who started the call would play.
- Text goes in two ways: `note(text, channel)` = `session.context.append` on the data channel (`commentary` or
  `developer`), `say_to()` = `thread/realtime/appendText` with `role: user` (a user turn, always answered).
"""
import asyncio, fractions, json, os, time, wave
from pathlib import Path

import av
import numpy as np
from aiortc import MediaStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription

from appserver import AppServer

SR, OUT_SR, FRAME = 16_000, 48_000, 320
HERE = Path(__file__).parent


class Mixer(MediaStreamTrack):
    """20 ms PCM16 frames at 48 kHz. Sum of every source's queued 16 kHz audio, else silence."""
    kind = 'audio'

    def __init__(self):
        super().__init__()
        self.src, self.t0, self.n = {}, None, 0

    def push(self, name, x16):
        self.src[name] = np.concatenate([self.src.get(name, np.zeros(0, np.float32)), x16.astype(np.float32)])

    async def recv(self):
        if self.t0 is None:
            self.t0 = time.monotonic()
        self.n += 1
        wait = self.t0 + self.n * 0.02 - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)
        chunk = np.zeros(FRAME, np.float32)
        for k, b in self.src.items():
            c = b[:FRAME]
            chunk[:len(c)] += c
            self.src[k] = b[FRAME:]
        up = np.interp(np.arange(FRAME * 3) / 3, np.arange(FRAME), chunk)
        f = av.AudioFrame.from_ndarray((np.clip(up, -1, 1) * 32767).astype(np.int16).reshape(1, -1), format='s16', layout='mono')
        f.sample_rate, f.pts, f.time_base = OUT_SR, (self.n - 1) * FRAME * 3, fractions.Fraction(1, OUT_SR)
        return f


class Tape:
    """Audio placed on the group clock (16 kHz). Each source keeps its own write cursor."""
    def __init__(self, clock):
        self.clock, self.x, self.cur = clock, np.zeros(SR * 600, np.float32), {}

    def add(self, name, x):
        at = self.cur.get(name)
        if at is None:
            at = int(self.clock() * SR)
        end = at + len(x)
        if end > len(self.x):
            self.x = np.concatenate([self.x, np.zeros(end - len(self.x) + SR * 60, np.float32)])
        self.x[at:end] += x
        self.cur[name] = end

    def save(self, path):
        n = max(self.cur.values(), default=0)
        with wave.open(str(path), 'wb') as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
            w.writeframes((np.clip(self.x[:n], -1, 1) * 32767).astype(np.int16).tobytes())


class Spirit:
    def __init__(self, group, name, voice, prompt):
        self.g, self.name, self.voice, self.prompt = group, name, voice, prompt
        self.track, self.events = Mixer(), []
        self.speaking_since = None

    def log(self, kind, **kw):
        self.g.log(kind, spirit=self.name, **kw)

    async def start(self):
        self.pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        self.pc.addTrack(self.track)
        self.dc = self.pc.createDataChannel('oai-events')
        self.dc.on('message', self._on_msg)

        @self.pc.on('track')
        def on_track(t):
            asyncio.ensure_future(self._pull(t))

        await self.pc.setLocalDescription(await self.pc.createOffer())
        s = self.g.server
        self.tid = (await s.call('thread/start', {'ephemeral': True, 'cwd': str(HERE), 'approvalPolicy': 'never', 'sandbox': 'read-only'}))['thread']['id']
        await s.call('thread/realtime/start', {
            'threadId': self.tid, 'version': 'v3', 'outputModality': 'audio', 'includeStartupContext': False,
            'clientManagedHandoffs': True, 'voice': self.voice, 'prompt': self.prompt,
            'transport': {'type': 'webrtc', 'sdp': self.pc.localDescription.sdp}})
        e = await s.until(lambda x: x.get('params', {}).get('threadId') == self.tid and
                          x.get('method') in ('thread/realtime/sdp', 'thread/realtime/error'), 30)
        assert e and e['method'] == 'thread/realtime/sdp', e
        await self.pc.setRemoteDescription(RTCSessionDescription(sdp=e['params']['sdp'], type='answer'))
        while self.dc.readyState != 'open':
            await asyncio.sleep(.05)
        self.log('connected')

    async def _pull(self, t):
        rs = av.AudioResampler(format='s16', layout='mono', rate=SR)
        while True:
            try:
                f = await t.recv()
            except Exception:
                return
            for g in rs.resample(f):
                x = g.to_ndarray().reshape(-1).astype(np.float32) / 32768
                self.g.on_audio(self, x)

    def _on_msg(self, m):
        ev = json.loads(m)
        typ = ev.get('type')
        if typ in ('output_audio.delta', 'turn.delta', 'output_transcript.added'):
            return
        ev['_t'] = self.g.now()
        self.events.append(ev)
        turn = ev.get('turn') or {}
        if typ == 'turn.created' and turn.get('role') == 'assistant':
            self.speaking_since = ev['_t']
            self.log('speak_start')
            self.g.on_speak_start(self)
        elif typ == 'turn.done':
            if turn.get('role') == 'assistant':
                self.speaking_since = None
                self.log('said', text=turn.get('transcript'))
                self.g.on_said(self, turn.get('transcript') or '')
            else:
                self.log('heard', text=turn.get('transcript'))
        elif typ == 'delegation.created':
            self.dc.send(json.dumps({'type': 'delegation.context.append', 'delegation_item_id': ev['item']['id'], 'channel': 'speakable',
                                     'content': [{'type': 'input_text', 'text': '裏で調べることは何もありません。会話の内容から、あなた自身がそのまま答えてください。'}]}))
            self.log('delegation', text=(ev['item'].get('content') or [{}])[0].get('text'))
        elif typ == 'error' or 'error' in typ:
            self.log('dc_error', event=ev)

    def note(self, text, channel='commentary'):
        self.dc.send(json.dumps({'type': 'session.context.append', 'channel': channel, 'content': [{'type': 'input_text', 'text': text}]}))
        self.log('note', text=text, channel=channel)

    async def say_to(self, text):
        self.log('user_text', text=text)
        await self.g.server.call('thread/realtime/appendText', {'threadId': self.tid, 'role': 'user', 'text': text})

    async def stop(self):
        try:
            await self.g.server.call('thread/realtime/stop', {'threadId': self.tid})
        except Exception:
            pass
        await self.pc.close()


class Group:
    """relay: None | 'audio' (voice into the other Spirits' microphone + a speaker note on `note_channel`)
                | 'text-commentary' / 'text-developer' (transcript as a note on that channel)
                | 'text-turn' (transcript as a user turn)"""
    def __init__(self, spirits, relay=None, note_channel='developer'):
        self.note_channel = note_channel
        self.t0 = time.monotonic()
        self.relay, self.timeline = relay, []
        self.device = Tape(self.now)
        self.spec = spirits
        self.spirits = []

    def now(self):
        return round(time.monotonic() - self.t0, 2)

    def log(self, kind, **kw):
        self.timeline.append({'t': self.now(), 'kind': kind, **kw})

    async def start(self):
        env = dict(os.environ); env.pop('OPENAI_API_KEY', None)
        self.server = await AppServer(['codex'], env).start()
        self.codex = (await (await asyncio.create_subprocess_exec('codex', '--version', stdout=asyncio.subprocess.PIPE)).communicate())[0].decode().strip()
        self.spirits = [Spirit(self, n, v, p) for n, v, p in self.spec]
        await asyncio.gather(*[s.start() for s in self.spirits])
        self.by_name = {s.name: s for s in self.spirits}
        return self

    def others(self, sp):
        return [s for s in self.spirits if s is not sp]

    def on_audio(self, sp, x):
        self.device.add(sp.name, x)
        if self.relay == 'audio':
            for o in self.others(sp):
                o.track.push(sp.name, x)

    def on_speak_start(self, sp):
        if self.relay == 'audio':
            for o in self.others(sp):
                o.note(f'[話者メモ] 今話し始めたのは{sp.name}の声です。', self.note_channel)

    def on_said(self, sp, text):
        if not text:
            return
        if self.relay in ('text-commentary', 'text-developer'):
            for o in self.others(sp):
                o.note(f'[{sp.name}] {text}', self.relay.split('-')[1])
        elif self.relay == 'text-turn':
            for o in self.others(sp):
                asyncio.ensure_future(o.say_to(f'[{sp.name}] {text}'))

    def anyone_speaking(self):
        return any(s.speaking_since is not None for s in self.spirits)

    async def quiet(self, settle=2.0, limit=30.0):
        """Wait until nobody has spoken for `settle` seconds (or `limit`)."""
        end = time.monotonic() + limit
        while time.monotonic() < end:
            last = max((e['_t'] for s in self.spirits for e in s.events if e.get('type') in ('turn.created', 'turn.done')), default=0)
            if not self.anyone_speaking() and self.now() - last >= settle:
                return True
            await asyncio.sleep(.05)
        return False

    async def stop(self, label):
        await asyncio.gather(*[s.stop() for s in self.spirits])
        await self.server.close()
        (HERE / 'work').mkdir(exist_ok=True)
        self.device.save(HERE / f'work/{label}-device.wav')

    def said(self):
        return [e for e in self.timeline if e['kind'] == 'said']
