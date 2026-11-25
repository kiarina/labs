"""Play a scripted multi-person conversation into a gpt-live call and note who is speaking.

usage: python call.py <label> <none|oracle|ecapa>

- none:   no speaker notes (the prompt only names the three people)
- oracle: a note with the true speaker at the moment each line starts
- ecapa:  a note from speaker identification on the audio actually sent (Silero VAD + ECAPA-TDNN,
          identified after 1.0 s of speech or at the end of a shorter utterance)

Notes go straight onto the `oai-events` data channel as `session.context.append` with
`channel: commentary` (not spoken). The call is started through `codex app-server` with the
ChatGPT login (Codex's default gpt-live model). Results: results/<label>.json, audio in work/.
"""
import asyncio, fractions, json, os, sys, time, wave
from pathlib import Path

import av
import numpy as np
import onnxruntime as ort
from aiortc import MediaStreamTrack, RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from speaker import MODELS, Ecapa, Identifier, say

HERE = Path(__file__).parent
SCN = json.loads((HERE / 'scenario.json').read_text())
AI = SCN['assistant']
NAMES = '・'.join(f'{n}さん' for n in SCN['people'])
PROMPT = (f'あなたは「{AI}」という名前の音声アシスタントです。今、{NAMES}の{len(SCN["people"])}人と同じ通話にいます。'
          f'{len(SCN["people"])}人は互いに話し合い、ときどきあなたに話しかけます。「{AI}」と呼びかけられたときだけ、日本語で短く（1〜2文）答えてください。'
          '人どうしの会話には口をはさまないでください。調べものや作業を頼まれることはないので、委譲はしないでください。')
NOTE_RULE = ('通話のシステムが声を聞き分け、誰かが話し始めるたびに「[話者メモ] …」で誰の声かを知らせます。'
             '誰が話しているかは、このメモで判断してください。メモには返事をしないでください。')
GAP_PEOPLE, GAP_AFTER_AI, AI_TIMEOUT, AI_SETTLE = 0.6, 0.8, 25.0, 2.0
DELEGATION_REPLY = '裏で調べることは何もありません。ここまでの会話の内容から、あなた自身がそのまま答えてください。'
SR, OUT_SR = 16_000, 48_000


class Playout(MediaStreamTrack):
    """20 ms PCM16 frames at 48 kHz: queued speech, else silence. Taps every sent sample (16 kHz) to `on_samples`."""
    kind = 'audio'

    def __init__(self, on_samples):
        super().__init__()
        self.buf, self.on_samples, self.t0, self.n = np.zeros(0, np.float32), on_samples, None, 0
        self.sent = 0  # 16 kHz samples sent so far

    def play(self, x16):
        self.buf = np.concatenate([self.buf, x16.astype(np.float32)])

    @property
    def pending(self):
        return len(self.buf)

    async def recv(self):
        if self.t0 is None:
            self.t0 = time.monotonic()
        self.n += 1
        wait = self.t0 + self.n * 0.02 - time.monotonic()
        if wait > 0:
            await asyncio.sleep(wait)
        chunk, self.buf = self.buf[:320], self.buf[320:]
        chunk = np.pad(chunk, (0, 320 - len(chunk)))
        self.on_samples(chunk, self.sent)
        self.sent += 320
        up = np.interp(np.arange(960) / 3, np.arange(320), chunk)
        f = av.AudioFrame.from_ndarray((np.clip(up, -1, 1) * 32767).astype(np.int16).reshape(1, -1), format='s16', layout='mono')
        f.sample_rate, f.pts, f.time_base = OUT_SR, (self.n - 1) * 960, fractions.Fraction(1, OUT_SR)
        return f


class Vad:
    """Silero VAD v5 on 512-sample chunks with the 64-sample context."""
    def __init__(self):
        self.s = ort.InferenceSession(str(MODELS / 'silero_vad.onnx'))
        self.state, self.ctx = np.zeros((2, 1, 128), np.float32), np.zeros(64, np.float32)

    def __call__(self, x512):
        x = np.concatenate([self.ctx, x512]).reshape(1, -1).astype(np.float32)
        out, self.state = self.s.run(None, {'input': x, 'state': self.state, 'sr': np.array(SR, np.int64)})
        self.ctx = x512[-64:]
        return float(out.reshape(-1)[0])


class EcapaNotes:
    """Utterance = speech from VAD > 0.5 until 0.4 s below 0.35. Identify once per utterance (after 1.0 s of
    speech, or at the end of a 0.4 s+ utterance); note only when the speaker differs from the last note."""
    def __init__(self, ident, send):
        self.ident, self.send, self.vad, self.last = ident, send, Vad(), 'start'
        self.decisions = []
        self.pending, self.speech, self.quiet, self.done = np.zeros(0, np.float32), [], 0, False

    def feed(self, x, at):
        self.pending = np.concatenate([self.pending, x])
        while len(self.pending) >= 512:
            c, self.pending = self.pending[:512], self.pending[512:]
            p = self.vad(c)
            if self.speech or p > 0.5:
                self.speech.append(c)
                self.quiet = self.quiet + 1 if p < 0.35 else 0
                n = len(self.speech) * 512
                if not self.done and n >= SR * 1.0:
                    self._decide(at)
                if self.quiet * 512 >= SR * 0.4:
                    if not self.done and n >= SR * 0.4:
                        self._decide(at)
                    self.speech, self.quiet, self.done = [], 0, False

    def _decide(self, at):
        self.done = True
        who, scores = self.ident.identify(np.concatenate(self.speech))
        scores = {k: round(v, 3) for k, v in scores.items()}
        self.decisions.append({'audio_s': round(at / SR, 2), 'who': who, 'scores': scores})
        if who != self.last:
            self.last = who
            self.send(who, scores, at)


async def main():
    label, mode = sys.argv[1], sys.argv[2]
    assert mode in ('none', 'oracle', 'ecapa')
    env = dict(os.environ); env.pop('OPENAI_API_KEY', None)
    t0 = time.monotonic()
    now = lambda: round(time.monotonic() - t0, 2)
    timeline, dc_events = [], []
    log = lambda kind, **kw: timeline.append({'t': now(), 'kind': kind, **kw})

    clips = {i['id']: say(SCN['people'][i['who']], i['text'], HERE / f'work/voice/{i["id"]:02d}-{i["who"]}.wav') for i in SCN['lines']}
    ident = None
    if mode == 'ecapa':
        ident = Identifier(Ecapa(), threshold=0.45)
        for name, voice in SCN['people'].items():
            ident.enroll(name, [say(voice, t, HERE / f'work/voice/enroll-{name}-{k}.wav') for k, t in enumerate(SCN['enroll'])])

    loop = asyncio.get_running_loop()
    sent_audio = []
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    dc = pc.createDataChannel('oai-events')

    def note(who, why, extra=None):
        text = f'[話者メモ] 今話し始めたのは{who}さんの声です。' if who else '[話者メモ] 今話し始めたのは、聞き分けられない声です。'
        dc.send(json.dumps({'type': 'session.context.append', 'channel': 'commentary', 'content': [{'type': 'input_text', 'text': text}]}))
        log('note', who=who, by=why, **(extra or {}))

    notes = EcapaNotes(ident, lambda who, scores, at: loop.call_soon_threadsafe(note, who, 'ecapa', {'scores': scores, 'audio_s': round(at / SR, 2)})) if ident else None

    def on_samples(x, at):
        sent_audio.append(x)
        if notes:
            notes.feed(x, at)

    track = Playout(on_samples)
    pc.addTrack(track)
    received = []

    @pc.on('track')
    def on_track(t):
        async def pull():
            rs = av.AudioResampler(format='s16', layout='mono', rate=SR)
            while True:
                try:
                    f = await t.recv()
                except Exception:
                    return
                for g in rs.resample(f):
                    received.append(g.to_ndarray().reshape(-1))
        asyncio.ensure_future(pull())

    def on_msg(m):
        ev = json.loads(m)
        if ev.get('type') in ('output_audio.delta', 'turn.delta'):
            return
        ev['_t'] = now(); dc_events.append(ev)
        if ev.get('type') == 'delegation.created':
            # Nothing to delegate in this lab: hand it back so the voice answers from the conversation.
            dc.send(json.dumps({'type': 'delegation.context.append', 'delegation_item_id': ev['item']['id'], 'channel': 'speakable',
                                'content': [{'type': 'input_text', 'text': DELEGATION_REPLY}]}))
            log('delegation', text=ev['item']['content'][0].get('text'))
    dc.on('message', on_msg)
    await pc.setLocalDescription(await pc.createOffer())

    sys.path.insert(0, str(HERE))
    from appserver import AppServer
    s = await AppServer(['codex'], env).start()
    out = {'label': label, 'mode': mode, 'prompt': PROMPT + (NOTE_RULE if mode != 'none' else ''), 'codex': None}
    try:
        out['codex'] = (await (await asyncio.create_subprocess_exec('codex', '--version', stdout=asyncio.subprocess.PIPE)).communicate())[0].decode().strip()
        tid = (await s.call('thread/start', {'ephemeral': True, 'cwd': str(HERE), 'approvalPolicy': 'never', 'sandbox': 'read-only'}))['thread']['id']
        await s.call('thread/realtime/start', {'threadId': tid, 'version': 'v3', 'outputModality': 'audio', 'includeStartupContext': False, 'clientManagedHandoffs': True,
                                               'prompt': out['prompt'], 'transport': {'type': 'webrtc', 'sdp': pc.localDescription.sdp}})
        e = await s.until(lambda x: x.get('method') in ('thread/realtime/sdp', 'thread/realtime/error'), 30)
        assert e and e['method'] == 'thread/realtime/sdp', e
        await pc.setRemoteDescription(RTCSessionDescription(sdp=e['params']['sdp'], type='answer'))
        while dc.readyState != 'open':
            await asyncio.sleep(.05)
        log('connected')
        await asyncio.sleep(2)

        def ai_turns():
            return [x for x in dc_events if x.get('type') == 'turn.done' and x['turn'].get('role') == 'assistant']

        def ai_open():
            done = {x['turn']['id'] for x in ai_turns()}
            return any(x.get('type') == 'turn.created' and x['turn'].get('role') == 'assistant' and x['turn']['id'] not in done for x in dc_events)

        async def settle(limit):
            end = time.monotonic() + limit
            while time.monotonic() < end:
                last = max((x['_t'] for x in dc_events if x.get('type') in ('turn.created', 'turn.done', 'delegation.created')), default=0)
                if not ai_open() and now() - last >= AI_SETTLE:
                    return
                await asyncio.sleep(.05)

        for line in SCN['lines']:
            before = len(ai_turns())
            log('line_start', id=line['id'], who=line['who'], to=line['to'], text=line['text'])
            if mode == 'oracle':
                note(line['who'], 'oracle')
            track.play(clips[line['id']])
            while track.pending:
                await asyncio.sleep(.02)
            log('line_end', id=line['id'])
            if line['to'] == 'ai':
                end = time.monotonic() + AI_TIMEOUT
                while len(ai_turns()) == before and time.monotonic() < end:
                    await asyncio.sleep(.05)
                if len(ai_turns()) == before:
                    log('no_reply', id=line['id'])
                await settle(AI_TIMEOUT)
                await asyncio.sleep(GAP_AFTER_AI)
            else:
                await asyncio.sleep(GAP_PEOPLE)
        await settle(30)
        await s.call('thread/realtime/stop', {'threadId': tid})
    finally:
        await s.close(); await pc.close()

    out['timeline'] = timeline
    out['events'] = [x for x in dc_events if x.get('type') in ('turn.done', 'turn.created', 'session.context.appended', 'delegation.created', 'error', 'session.started')]
    Path(HERE / 'results').mkdir(exist_ok=True)
    (HERE / f'results/{label}.json').write_text(json.dumps(out, ensure_ascii=False, indent=1) + '\n')
    for name, chunks in (('sent', sent_audio), ('ai', received)):
        if chunks:
            x = np.concatenate(chunks)
            x = (np.clip(x, -1, 1) * 32767).astype(np.int16) if x.dtype != np.int16 else x
            with wave.open(str(HERE / f'work/{label}-{name}.wav'), 'wb') as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(x.tobytes())
    for x in out['events']:
        if x['type'] == 'turn.done':
            print(x['_t'], x['turn']['role'], x['turn'].get('transcript'))
    for x in timeline:
        if x['kind'] in ('note', 'no_reply'):
            print(x['t'], x['kind'], x.get('who'), x.get('scores', ''))

asyncio.run(main())
