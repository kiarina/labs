"""A three-person call with a camera: gpt-live hears the people, gets speaker notes and camera notes as text,
and delegates when it needs to look (the delegation is answered by a vision model from recent keyframes).

usage: python call.py <label> <none|plain|topic|light> [--keyframes change|interval] [--interval S] [--video FRAMES_DIR] [--speed X] [--faces on]
       SCENARIO=scenario-proactive.json python call.py ...   (default scenario.json)

- none:  no camera notes; gpt-live must delegate to know anything about the camera
- plain: a camera note whenever the picture changes (what changed, generic)
- topic: the same, but the note writer also gets the recent conversation and says what matters to the topic
- light: only short notes of eye-catching events (people coming or going, animals, ...), else nothing

--keyframes change (default): keep a frame when the picture differs from the last kept one;
            interval: keep one every --interval seconds (default 4). Up to 16 are kept for delegations.
--video DIR: the camera plays DIR/0000.jpg, 0001.jpg, ... at VIDEO_FPS in real time (from the first line),
             instead of the scripted still frames, at --speed (default 1.0). Lines may wait for a video time
             (in video seconds) with "at". After the last frame the camera keeps showing it.
--faces on: identify faces (faces.py, YuNet + SFace, a gallery of the enrollment photos frames/p-<name>-*.jpg) whenever the
            picture changes, send `[顔メモ] …` when who is on camera changes, and draw the boxes and names on the
            pictures a delegation sees.

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
import cv2

HERE = Path(__file__).parent
SCN = json.loads((HERE / os.environ.get('SCENARIO', 'scenario.json')).read_text())
AI = SCN['assistant']
NAMES = '・'.join(f'{n}さん' for n in SCN['people'])
LOOKS = '\n'.join(f'- {n}さん: {v}' for n, v in SCN.get('looks', {}).items()) or '（人の見た目の手がかりは無い）'
NOTE_MODEL, LOOK_MODEL = ('gpt-6.2-sol', 'low'), ('gpt-6.2-sol', 'low')
GAP_PEOPLE, GAP_AFTER_AI, AI_TIMEOUT, AI_SETTLE = 0.6, 0.8, 40.0, 2.0
KEYFRAMES, CAMERA_EVERY, INTERVAL_S, VIDEO_FPS = 16, 1.0, 4.0, 2.0

BASE = (f'あなたは「{AI}」という名前の音声アシスタントです。今、{NAMES}の3人と同じ通話にいます。通話にはカメラもつながっていて、'
        + SCN.get('situation', 'テーブルのまわりの3人が映っています。') + '3人は互いに話し合い、ときどきあなたに話しかけます。'
        + SCN.get('answer_rule', f'「{AI}」と呼びかけられたときだけ、日本語で短く（1〜2文）答えてください。人どうしの会話には口をはさまないでください。')
        + '通話のシステムが声を聞き分け、誰かが話し始めるたびに「[話者メモ] …」で誰の声かを知らせます。誰が話しているかは、このメモで判断してください。'
        + 'メモには返事をしないでください。')
CAMERA_RULE = {
    'none': 'あなたはカメラの映像を直接見られません。映像について答える必要があるときは、確かめたいことを委譲してください。'
            '委譲すると、カメラの直近の画像を見た答えが返ります。',
    'plain': '通話のシステムがカメラの映像の変化を「[カメラ] …」で知らせます（知らせには返事をしないでください）。'
             '知らせで分かることはそのまま答え、知らせで足りないことや、もっと詳しく確かめたいことは、確かめたいことを委譲してください。'
             '委譲すると、カメラの直近の画像を見た答えが返ります。',
}
CAMERA_RULE['topic'] = CAMERA_RULE['light'] = CAMERA_RULE['plain']
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
NOTE_ASK['light'] = ('あなたは、ビデオ通話のカメラの映像を、目の見えない音声アシスタントに知らせる係です。1枚目が前の映像、2枚目が今の映像です。'
                     '人の出入り、動物、物を落とすなど、その場にいる人なら思わず一言触れそうな目立つ出来事があったときだけ、それを15文字くらいの短い言葉で書いてください。'
                     '人は次の見た目で名前を判断してください。\n{looks}\n'
                     'それ以外の変化（物を置く・持つ、姿勢、カメラの揺れ）は書かず、「なし」とだけ書いてください。前に伝えた内容: {last}')
LOOK_ASK = ('あなたは、ビデオ通話のカメラを見て、音声アシスタントの代わりに答える係です。答えはアシスタントがそのまま声で言います。'
            '1枚目は最近の映像の変化を時刻順に並べた最大16枚（左上から右へ、各コマの数字は何秒前か）、2枚目が今の映像です。'
            '人は次の見た目で名前を判断してください。\n{looks}\nここまでの会話（[ ]は声で聞き分けた話者）:\n{talk}\n\n'
            '確かめたいこと: {ask}\nこれを言った人（声の聞き分け）: {asker}\n\n画像と会話から分かることだけを、話し言葉の日本語1〜3文で答えてください。分からないことは分からないと言ってください。')
FACE_RULE = ('通話のシステムがカメラに映っている顔を見分け、映っている人が変わるたびに「[顔メモ] …」で、誰がどこに映っているかを知らせます。'
             '誰が映っているかは、このメモで判断してください。メモには返事をしないでください。')
FACE_LOOKS = '画像の緑の枠と名前は、登録した顔の認識の結果です（橙の枠は登録されていない人）。'
FONT = '/System/Library/Fonts/ヒラギノ角ゴシック W6.ttc'
SAY_NONE = '裏で調べることは何もありません。ここまでの会話の内容から、あなた自身がそのまま答えてください。'


class Camera:
    """The scripted camera: `show(key)` changes the picture; a keyframe is kept when the picture differs from the last kept one."""
    def __init__(self, now, keyframes='change', video=None, interval=INTERVAL_S, speed=1.0):
        self.now, self.key, self.keyframes, self.last_arr = now, None, [], None
        self.interval, self.speed = interval, speed
        self.mode, self.video, self.video_t0 = keyframes, Path(video) if video else None, None
        self.video_n = len(list(self.video.glob('*.jpg'))) if self.video else 0

    def show(self, key):
        self.key = key

    def play(self):
        self.video_t0 = time.monotonic()

    def video_time(self):
        return 0.0 if self.video_t0 is None else (time.monotonic() - self.video_t0) * self.speed

    def follow(self):
        if self.video and self.video_t0 is not None:
            self.key = f'{min(int(self.video_time() * VIDEO_FPS), self.video_n - 1):04d}'

    def path(self, key=None):
        if self.video:
            return self.video / f'{key or self.key}.jpg'
        return HERE / 'frames' / f'{key or self.key}.jpg'

    def tick(self):
        self.follow()
        if not self.key:
            return False
        if self.mode == 'interval':
            if not self.keyframes or self.now() - self.keyframes[-1][0] >= self.interval - 0.01:
                self.keyframes.append((self.now(), self.key))
                self.keyframes = self.keyframes[-KEYFRAMES:]
                return True
            return False
        a = np.asarray(Image.open(self.path()).convert('L').resize((160, 90)), np.float32)
        if self.last_arr is None or np.abs(a - self.last_arr).mean() > 2.0:
            self.last_arr = a
            self.keyframes.append((self.now(), self.key))
            self.keyframes = self.keyframes[-KEYFRAMES:]
            return True
        return False

    def grid(self, out, path=None):
        path = path or self.path
        cells = self.keyframes[-KEYFRAMES:]
        W, H = 320, 180
        img = Image.new('RGB', (W * 4, H * 4), 'black')
        d = ImageDraw.Draw(img)
        font = ImageFont.load_default(size=22)
        for i, (t, key) in enumerate(cells):
            x, y = (i % 4) * W, (i // 4) * H
            img.paste(Image.open(path(key)).convert('RGB').resize((W, H)), (x, y))
            label = f'-{self.now() - t:.0f}s'
            d.rectangle([x, y, x + 70, y + 28], fill='black')
            d.text((x + 4, y + 2), label, fill='white', font=font)
        img.save(out, quality=85)
        return out


async def main():
    label, mode = sys.argv[1], sys.argv[2]
    assert mode in ('none', 'plain', 'topic', 'light')
    opts = dict(zip(sys.argv[3::2], sys.argv[4::2]))
    kf_mode, video = opts.get('--keyframes', 'change'), opts.get('--video')
    interval, speed = float(opts.get('--interval', INTERVAL_S)), float(opts.get('--speed', 1.0))
    use_faces = opts.get('--faces') == 'on'
    looks = FACE_LOOKS if use_faces else LOOKS
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

    voice_dir = HERE / 'work' / 'voice' / Path(os.environ.get('SCENARIO', 'scenario.json')).stem
    clips = {l['id']: say(SCN['people'][l['who']], l['text'], voice_dir / f'{l["id"]:02d}-{l["who"]}.wav') for l in SCN['lines']}
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
    facer = None
    if use_faces:
        from faces import Faces
        facer = Faces('gallery')
        for n in SCN['people']:
            facer.enroll(n, sorted(HERE.glob(f'frames/p-{n}-*.jpg')))
    cam = Camera(now, kf_mode, video, interval, speed)
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

    face_cache = {}

    def faces_of(key):
        if key not in face_cache:
            face_cache[key] = facer.identify(cv2.imread(str(cam.path(key))))
        return face_cache[key]

    def annotated(key):
        out = work / 'faces' / f'{key}.jpg'
        if not out.exists():
            out.parent.mkdir(exist_ok=True)
            img = Image.open(cam.path(key)).convert('RGB')
            d = ImageDraw.Draw(img)
            font = ImageFont.truetype(FONT, 34) if Path(FONT).exists() else ImageFont.load_default(size=34)
            for f in faces_of(key):
                x, y, w, h = f['box']
                color = (0, 220, 0) if f['name'] else (255, 150, 0)
                d.rectangle([x, y, x + w, y + h], outline=color, width=5)
                name = f"{f['name']}さん" if f['name'] else '登録されていない人'
                d.rectangle([x, y - 44, x + 40 + 36 * len(name), y], fill=color)
                d.text((x + 6, y - 42), name, fill='black', font=font)
            img.save(out, quality=90)
        return out

    def roster(faces):
        known = [f"{f['where']}に{f['name']}さん" for f in faces if f['name']]
        unknown = sum(1 for f in faces if not f['name'])
        parts = known + ([f'登録されていない人が{unknown}人'] if unknown else [])
        return '、'.join(parts) if parts else '誰も映っていません'

    async def answer(item):
        d = delegations[item['id']]
        ask = item['content'][0].get('text', '')
        if use_faces:
            await asyncio.to_thread(lambda: [annotated(k) for _, k in cam.keyframes] + [annotated(cam.key)])
        grid = cam.grid(work / f'grid-{len(delegations):02d}.jpg', annotated if use_faces else None)
        r = await vision.ask(*LOOK_MODEL, LOOK_ASK.format(looks=looks, talk=talk_text(), ask=ask, asker=(f'{d["asker"]}さん' if d['asker'] else '分からない')),
                             [grid, annotated(cam.key) if use_faces else cam.path()])
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
        prev_key, face_key, face_said, face_names = None, None, None, set()
        while True:
            changed = cam.tick()
            if use_faces and cam.key and cam.key != face_key:
                face_key = cam.key
                found = await asyncio.to_thread(faces_of, face_key)
                said = roster(found)
                if said != face_said:
                    names = {f['name'] for f in found if f['name']}
                    gone = [f'{n}さん' for n in sorted(face_names - names)]
                    text = f'[顔メモ] 今カメラに映っているのは、{said}。' + (f'（{"・".join(gone)}は映らなくなりました）' if gone else '')
                    context(text, 'face_note', frame=face_key, faces=[{k: f[k] for k in ('name', 'where', 'score')} for f in found])
                    face_said, face_names = said, names
            if mode != 'none' and cam.key != noted_key and not busy and cam.keyframes:
                busy, key, before = True, cam.key, prev_key or cam.key
                ask = NOTE_ASK[mode].format(looks=looks, talk=talk_text(6), last=last_note)
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
    prompt = BASE + CAMERA_RULE[mode] + (FACE_RULE if use_faces else '')
    out = {'label': label, 'mode': mode, 'keyframes': kf_mode, 'interval': interval if kf_mode == 'interval' else None,
           'video': bool(video), 'speed': speed if video else None, 'faces': use_faces, 'scenario': os.environ.get('SCENARIO', 'scenario.json'),
           'prompt': prompt, 'note_model': NOTE_MODEL, 'look_model': LOOK_MODEL}
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

        if video:
            cam.play()
        else:
            cam.show(SCN.get('start_frame', 'f00'))
        await asyncio.sleep(3)
        for line in SCN['lines']:
            await settle(AI_TIMEOUT)  # the people wait until the assistant has finished (and any delegation is answered)
            while video and cam.video_time() < line.get('at', 0):
                await asyncio.sleep(.05)
            if line.get('frame'):
                cam.show(line['frame'])
                log('frame', key=line['frame'])
            log('line_start', id=line['id'], who=line['who'], to=line['to'], text=line['text'],
                **({'video_s': round(cam.video_time(), 1), 'video_frame': cam.key} if video else {}))
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
                log('frame', key=line['after'], event=line.get('event'))
            if line.get('pause'):
                log('pause', seconds=line['pause'], event=line.get('event'))
                await asyncio.sleep(line['pause'])
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
