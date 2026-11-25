"""A three-person call with a camera: gpt-live hears the people, gets speaker notes and camera notes as text,
and delegates when it needs to look (the delegation is answered by a vision model from recent keyframes).

usage: python call.py <label> <none|plain|topic>

- none:  no camera notes; gpt-live must delegate to know anything about the camera
- plain: a camera note whenever the picture changes (what changed, generic)
- topic: the same, but the note writer also gets the recent conversation and says what matters to the topic

Every condition: speaker notes from Silero VAD + ECAPA-TDNN (`[話者メモ] …`), and delegations answered by
gpt-6.2-sol (effort low) from a 4x4 grid of the last 16 keyframes plus the current frame, the conversation so far
and the people's looks. Camera notes are written by gpt-6.2-sol (effort low). Notes go onto the `oai-events`
data channel as `session.context.append` with `channel: commentary`; delegation answers as
`delegation.context.append` with `channel: speakable`. Results: results/<label>.json, audio and grids in work/.
"""
import asyncio, json, os, sys, time, wave
from pathlib import Path

import av
import numpy as np
from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription
from PIL import Image, ImageDraw, ImageFont

from appserver import AppServer
from media import SR, EcapaNotes, Playout
from speaker import Ecapa, Identifier, say
from vision import Vision

HERE = Path(__file__).parent
SCN = json.loads((HERE / 'scenario.json').read_text())
AI = SCN['assistant']
NAMES = '・'.join(f'{n}さん' for n in SCN['people'])
LOOKS = '\n'.join(f'- {n}さん: {v}' for n, v in SCN['looks'].items())
NOTE_MODEL, LOOK_MODEL = ('gpt-6.2-sol', 'low'), ('gpt-6.2-sol', 'low')
GAP_PEOPLE, GAP_AFTER_AI, AI_TIMEOUT, AI_SETTLE = 0.6, 0.8, 40.0, 2.0
KEYFRAMES, CAMERA_EVERY = 16, 1.0

BASE = (f'あなたは「{AI}」という名前の音声アシスタントです。今、{NAMES}の3人と同じ通話にいます。通話にはカメラもつながっていて、'
        'テーブルのまわりの3人が映っています。3人は互いに話し合い、ときどきあなたに話しかけます。'
        f'「{AI}」と呼びかけられたときだけ、日本語で短く（1〜2文）答えてください。人どうしの会話には口をはさまないでください。'
        '通話のシステムが声を聞き分け、誰かが話し始めるたびに「[話者メモ] …」で誰の声かを知らせます。誰が話しているかは、このメモで判断してください。'
        'メモには返事をしないでください。')
CAMERA_RULE = {
    'none': 'あなたはカメラの映像を直接見られません。映像について答える必要があるときは、確かめたいことを委譲してください。'
            '委譲すると、カメラの直近の画像を見た答えが返ります。',
    'plain': '通話のシステムがカメラの映像の変化を「[カメラ] …」で知らせます（知らせには返事をしないでください）。'
             '知らせで分かることはそのまま答え、知らせで足りないことや、もっと詳しく確かめたいことは、確かめたいことを委譲してください。'
             '委譲すると、カメラの直近の画像を見た答えが返ります。',
}
CAMERA_RULE['topic'] = CAMERA_RULE['plain']
NOTE_ASK = {
    'plain': ('あなたは、ビデオ通話のカメラの映像を、目の見えない音声アシスタントに文字で伝える係です。1枚目が前の映像、2枚目が今の映像です。'
              '前から何が変わったかを、日本語の短い1文で書いてください。人は次の見た目で名前を判断してください。\n{looks}\n'
              'カメラの小さな揺れや画角の違い、物の位置の小さなずれは変化として書かないでください。大きな変化が無ければ「なし」とだけ書いてください。前に伝えた内容: {last}'),
    'topic': ('あなたは、ビデオ通話のカメラの映像を、目の見えない音声アシスタントに文字で伝える係です。1枚目が前の映像、2枚目が今の映像です。'
              '前から何が変わったかを、日本語の短い1〜2文で書いてください。人は次の見た目で名前を判断してください。\n{looks}\n'
              '今の会話の流れは次のとおりです。会話の話題に関係するものは、数・種類・誰の物かなど、話題に役立つ細部を具体的に書いてください。'
              '話題に関係なくても、人の出入りや動物など目立つ出来事は短く書いてください。\n{talk}\n'
              'カメラの小さな揺れや画角の違い、物の位置の小さなずれは変化として書かないでください。大きな変化が無ければ「なし」とだけ書いてください。前に伝えた内容: {last}'),
}
LOOK_ASK = ('あなたは、ビデオ通話のカメラを見て、音声アシスタントの代わりに答える係です。答えはアシスタントがそのまま声で言います。'
            '1枚目は最近の映像の変化を時刻順に並べた最大16枚（左上から右へ、各コマの数字は何秒前か）、2枚目が今の映像です。'
            '人は次の見た目で名前を判断してください。\n{looks}\nここまでの会話（[ ]は声で聞き分けた話者）:\n{talk}\n\n'
            '確かめたいこと: {ask}\nこれを言った人（声の聞き分け）: {asker}\n\n画像と会話から分かることだけを、話し言葉の日本語1〜3文で答えてください。分からないことは分からないと言ってください。')
SAY_NONE = '裏で調べることは何もありません。ここまでの会話の内容から、あなた自身がそのまま答えてください。'


class Camera:
    """The scripted camera: `show(key)` changes the picture; a keyframe is kept when the picture differs from the last kept one."""
    def __init__(self, now):
        self.now, self.key, self.keyframes, self.last_arr = now, None, [], None

    def show(self, key):
        self.key = key

    def path(self, key=None):
        return HERE / 'frames' / f'{key or self.key}.jpg'

    def tick(self):
        if not self.key:
            return False
        a = np.asarray(Image.open(self.path()).convert('L').resize((160, 90)), np.float32)
        if self.last_arr is None or np.abs(a - self.last_arr).mean() > 2.0:
            self.last_arr = a
            self.keyframes.append((self.now(), self.key))
            self.keyframes = self.keyframes[-KEYFRAMES:]
            return True
        return False

    def grid(self, out):
        cells = self.keyframes[-KEYFRAMES:]
        W, H = 320, 180
        img = Image.new('RGB', (W * 4, H * 4), 'black')
        d = ImageDraw.Draw(img)
        font = ImageFont.load_default(size=22)
        for i, (t, key) in enumerate(cells):
            x, y = (i % 4) * W, (i // 4) * H
            img.paste(Image.open(self.path(key)).convert('RGB').resize((W, H)), (x, y))
            label = f'-{self.now() - t:.0f}s'
            d.rectangle([x, y, x + 70, y + 28], fill='black')
            d.text((x + 4, y + 2), label, fill='white', font=font)
        img.save(out, quality=85)
        return out


async def main():
    label, mode = sys.argv[1], sys.argv[2]
    assert mode in ('none', 'plain', 'topic')
    env = dict(os.environ); env.pop('OPENAI_API_KEY', None)
    t0 = time.monotonic()
    now = lambda: round(time.monotonic() - t0, 2)
    timeline, dc_events, talk = [], [], []
    def log(kind, **kw):
        timeline.append({'t': now(), 'kind': kind, **kw})
        if kind not in ('frame',):
            print(now(), kind, json.dumps(kw, ensure_ascii=False)[:160], flush=True)
    work = HERE / 'work' / label
    work.mkdir(parents=True, exist_ok=True)

    clips = {l['id']: say(SCN['people'][l['who']], l['text'], HERE / f'work/voice/{l["id"]:02d}-{l["who"]}.wav') for l in SCN['lines']}
    ident = Identifier(Ecapa(), threshold=0.35)
    for name, voice in SCN['people'].items():
        ident.enroll(name, [say(voice, t, HERE / f'work/voice/enroll-{name}-{k}.wav') for k, t in enumerate(SCN['enroll'])])

    loop = asyncio.get_running_loop()
    pc = RTCPeerConnection(RTCConfiguration(iceServers=[]))
    dc = pc.createDataChannel('oai-events')
    heard = {'who': None}

    def context(text, kind, **kw):
        dc.send(json.dumps({'type': 'session.context.append', 'channel': 'commentary', 'content': [{'type': 'input_text', 'text': text}]}))
        log(kind, text=text, **kw)

    def speaker_note(who, scores, at):
        heard['who'] = who
        context(f'[話者メモ] 今話し始めたのは{who}さんの声です。' if who else '[話者メモ] 今話し始めたのは、聞き分けられない声です。',
                'note', who=who, scores=scores)

    notes = EcapaNotes(ident, lambda who, scores, at: loop.call_soon_threadsafe(speaker_note, who, scores, at))
    sent_audio = []

    def on_samples(x, at):
        sent_audio.append(x)
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

    vision = await Vision(env, HERE).start()
    cam = Camera(now)
    delegations = {}

    def talk_text(n=None):
        rows = talk[-n:] if n else talk
        return '\n'.join(f'[{w or "不明"}] {s}' if w != AI else f'{AI}: {s}' for w, s in rows) or '（まだ会話なし）'

    async def guard(coro, name):
        try:
            await coro
        except asyncio.CancelledError:
            raise
        except Exception as e:
            log('task_error', task=name, error=repr(e))
            raise

    async def answer(item):
        d = delegations[item['id']]
        ask = item['content'][0].get('text', '')
        grid = cam.grid(work / f'grid-{len(delegations):02d}.jpg')
        r = await vision.ask(*LOOK_MODEL, LOOK_ASK.format(looks=LOOKS, talk=talk_text(), ask=ask, asker=(f'{d["asker"]}さん' if d['asker'] else '分からない')), [grid, cam.path()])
        text = r['text'] or SAY_NONE
        dc.send(json.dumps({'type': 'delegation.context.append', 'delegation_item_id': item['id'], 'channel': 'speakable',
                            'content': [{'type': 'input_text', 'text': text}]}))
        d['replied'] = now()
        log('delegation_reply', ask=ask, text=text, seconds=r['seconds'], frames=[k for _, k in cam.keyframes], current=cam.key)

    def on_msg(m):
        ev = json.loads(m)
        if ev.get('type') in ('output_audio.delta', 'turn.delta'):
            return
        ev['_t'] = now(); dc_events.append(ev)
        if ev.get('type') == 'delegation.created':
            delegations[ev['item']['id']] = {'created': now(), 'replied': None, 'asker': heard['who']}
            log('delegation', text=ev['item']['content'][0].get('text'))
            asyncio.ensure_future(guard(answer(ev['item']), 'answer'))
        if ev.get('type') == 'turn.done':
            print(now(), ev['turn'].get('role'), ev['turn'].get('transcript', ''), flush=True)
            if ev['turn'].get('role') == 'assistant':
                talk.append((AI, ev['turn'].get('transcript', '')))
    dc.on('message', on_msg)

    async def camera_loop():
        last_note, noted_key, busy = '（まだ伝えていない）', None, False
        prev_key = None
        while True:
            changed = cam.tick()
            if mode != 'none' and cam.key != noted_key and not busy and cam.keyframes:
                busy, key, before = True, cam.key, prev_key or cam.key
                ask = NOTE_ASK[mode].format(looks=LOOKS, talk=talk_text(6), last=last_note)
                r = await vision.ask(*NOTE_MODEL, ask, [cam.path(before), cam.path(key)])
                text = r['text'].strip()
                noted_key, prev_key, busy = key, key, False
                if text and text != 'なし' and not text.startswith('なし'):
                    last_note = text
                    context(f'[カメラ] {text}', 'camera_note', frame=key, current=cam.key, seconds=r['seconds'])
                else:
                    log('camera_note_skipped', frame=key, text=text, seconds=r['seconds'])
            elif mode == 'none' and changed:
                prev_key = cam.key
            await asyncio.sleep(CAMERA_EVERY)

    await pc.setLocalDescription(await pc.createOffer())
    s = await AppServer(['codex'], env).start()
    prompt = BASE + CAMERA_RULE[mode]
    out = {'label': label, 'mode': mode, 'prompt': prompt, 'note_model': NOTE_MODEL, 'look_model': LOOK_MODEL}
    cam_task = None
    try:
        out['codex'] = (await (await asyncio.create_subprocess_exec('codex', '--version', stdout=asyncio.subprocess.PIPE)).communicate())[0].decode().strip()
        tid = (await s.call('thread/start', {'ephemeral': True, 'cwd': str(HERE), 'approvalPolicy': 'never', 'sandbox': 'read-only'}))['thread']['id']
        await s.call('thread/realtime/start', {'threadId': tid, 'version': 'v3', 'outputModality': 'audio', 'includeStartupContext': False,
                                               'clientManagedHandoffs': True, 'prompt': prompt,
                                               'transport': {'type': 'webrtc', 'sdp': pc.localDescription.sdp}})
        e = await s.until(lambda x: x.get('method') in ('thread/realtime/sdp', 'thread/realtime/error'), 30)
        assert e and e['method'] == 'thread/realtime/sdp', e
        await pc.setRemoteDescription(RTCSessionDescription(sdp=e['params']['sdp'], type='answer'))
        while dc.readyState != 'open':
            await asyncio.sleep(.05)
        log('connected')
        cam_task = asyncio.ensure_future(guard(camera_loop(), 'camera'))

        def ai_done():
            return [x for x in dc_events if x.get('type') == 'turn.done' and x['turn'].get('role') == 'assistant']

        def busy():
            done = {x['turn']['id'] for x in ai_done()}
            if any(x.get('type') == 'turn.created' and x['turn'].get('role') == 'assistant' and x['turn']['id'] not in done for x in dc_events):
                return True
            for d in delegations.values():
                if d['replied'] is None:
                    return True
                # After a reply, wait for the voice to start saying it (or give up after 15 s).
                spoke = any(x.get('type') == 'turn.created' and x['turn'].get('role') == 'assistant' and x['_t'] >= d['replied'] for x in dc_events)
                if not spoke and now() - d['replied'] < 15:
                    return True
            return False

        async def settle(limit):
            end = time.monotonic() + limit
            while time.monotonic() < end:
                last = max((x['_t'] for x in dc_events if x.get('type') in ('turn.created', 'turn.done', 'delegation.created')), default=0)
                if not busy() and now() - last >= AI_SETTLE:
                    return
                await asyncio.sleep(.05)
            log('settle_timeout')

        def answered_since(t):
            return any((x.get('type') == 'turn.created' and x['turn'].get('role') == 'assistant') or x.get('type') == 'delegation.created'
                       for x in dc_events if x['_t'] >= t)

        cam.show('f00')
        await asyncio.sleep(3)
        for line in SCN['lines']:
            await settle(AI_TIMEOUT)  # the people wait until the assistant has finished (and any delegation is answered)
            if line.get('frame'):
                cam.show(line['frame'])
                log('frame', key=line['frame'])
            log('line_start', id=line['id'], who=line['who'], to=line['to'], text=line['text'])
            track.play(clips[line['id']])
            while track.pending:
                await asyncio.sleep(.02)
            line_end = now()
            await asyncio.sleep(0.5)  # let the speaker note settle before logging who spoke
            talk.append((heard['who'], line['text']))
            log('line_end', id=line['id'])
            if line['to'] == 'ai':
                end = time.monotonic() + AI_TIMEOUT
                while not answered_since(line_end - 0.3) and time.monotonic() < end:
                    await asyncio.sleep(.05)
                if not answered_since(line_end - 0.3):
                    log('no_reply', id=line['id'])
                await settle(AI_TIMEOUT)
                gap = GAP_AFTER_AI
            else:
                gap = GAP_PEOPLE
            if line.get('after'):
                await asyncio.sleep(line.get('after_s', 0))
                cam.show(line['after'])
                log('frame', key=line['after'])
            await asyncio.sleep(gap)
        await settle(40)
        await s.call('thread/realtime/stop', {'threadId': tid})
    finally:
        if cam_task:
            cam_task.cancel()
        await s.close(); await vision.close(); await pc.close()

    out['timeline'] = timeline
    out['events'] = [x for x in dc_events if x.get('type') in ('turn.done', 'turn.created', 'delegation.created', 'error', 'session.started')]
    (HERE / 'results').mkdir(exist_ok=True)
    (HERE / f'results/{label}.json').write_text(json.dumps(out, ensure_ascii=False, indent=1) + '\n')
    for name, chunks in (('sent', sent_audio), ('ai', received)):
        if chunks:
            x = np.concatenate(chunks)
            x = (np.clip(x, -1, 1) * 32767).astype(np.int16) if x.dtype != np.int16 else x
            with wave.open(str(work / f'{name}.wav'), 'wb') as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(x.tobytes())
    for x in out['events']:
        if x['type'] == 'turn.done':
            print(x['_t'], x['turn']['role'], x['turn'].get('transcript'))
    for x in timeline:
        if x['kind'] in ('camera_note', 'delegation', 'delegation_reply', 'no_reply', 'settle_timeout'):
            print(x['t'], x['kind'], x.get('text', ''), x.get('seconds', ''))

asyncio.run(main())
