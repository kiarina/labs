#!/usr/bin/env python3
"""Loopback control plane for gpt-live-1-codex over ChatGPT-login WebRTC.

The Flutter app owns the PeerConnection, capture, playout slot and AEC; it sends
its SDP offer here. This server runs `codex app-server` (CLI 0.163.0, v3 / audio /
WebRTC, call base = chatgpt.com wham), returns the answer, and relays the
sideband events. Event kinds, roles and statuses are forwarded; transcript text
is forwarded for display (the app stores it only for synthetic sessions).
No Thinker: delegations receive a fixed short reply. OPENAI_API_KEY is removed.
"""
import asyncio, json, os, re, secrets, signal, sys, time
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
from websockets.asyncio.server import serve
from websockets.asyncio.client import connect

ROOT = Path(__file__).resolve().parents[1]
BIN = str(ROOT / 'work/cli/node_modules/.bin/codex')
VOICE = None  # thread/realtime/start `voice` (thread/realtime/listVoices), e.g. --voice=himari
PROMPT = ('You are a friendly Japanese voice assistant in an audio test. Answer the user yourself in '
          'natural Japanese, in two to four short sentences. Do not delegate and do not call tools. '
          'Only respond to the user; ignore sounds that are not addressed to you.')


class Client:
    def __init__(self, extra, env):
        self.extra, self.env, self.seq, self.pending, self.events = extra, env, 0, {}, []

    async def start(self):
        self.proc = await asyncio.create_subprocess_exec(BIN, 'app-server', *self.extra, stdin=-1, stdout=-1,
                                                         stderr=asyncio.subprocess.DEVNULL, env=self.env)
        self.reader = asyncio.create_task(self.read())
        await self.call('initialize', {'clientInfo': {'name': 'playout_slot_lab', 'version': '0.1.0'},
                                       'capabilities': {'experimentalApi': True}})
        self.send({'method': 'initialized', 'params': {}})
        return self

    def send(self, m):
        self.proc.stdin.write((json.dumps(m) + '\n').encode())

    async def read(self):
        while line := await self.proc.stdout.readline():
            try:
                m = json.loads(line)
            except ValueError:
                continue
            if 'id' in m and m['id'] in self.pending:
                self.pending.pop(m['id']).set_result(m)
            else:
                self.events.append(m)

    async def call(self, method, params):
        self.seq += 1
        f = asyncio.get_running_loop().create_future()
        self.pending[self.seq] = f
        self.send({'id': self.seq, 'method': method, 'params': params})
        return await asyncio.wait_for(f, 30)

    async def until(self, pred, seconds):
        end = asyncio.get_running_loop().time() + seconds
        while asyncio.get_running_loop().time() < end:
            if any(pred(e) for e in self.events):
                return True
            await asyncio.sleep(.05)
        return False

    async def close(self):
        self.proc.stdin.close()
        try:
            await asyncio.wait_for(self.proc.wait(), 5)
        except TimeoutError:
            self.proc.terminate()
            await self.proc.wait()
        await self.reader


class Session:
    def __init__(self, socket):
        self.socket, self.voice, self.tid, self.user, self.out = socket, None, None, '', ''
        self.kinds = {}

    async def emit(self, message_type, **fields):
        try:
            await self.socket.send(json.dumps({'type': message_type, **fields}, ensure_ascii=False))
        except Exception:
            pass

    async def relay(self, downstream):
        path = downstream.request.path
        assert re.fullmatch(r'/v1/live/rtc_[A-Za-z0-9_-]+', path), path
        allowed = {'authorization', 'chatgpt-account-id', 'openai-alpha', 'originator', 'user-agent',
                   'x-session-id', 'x-codex-turn-metadata', 'openai-beta'}
        headers = {k: v for k, v in downstream.request.headers.raw_items() if k.lower() in allowed}
        async with connect('wss://api.openai.com' + path, additional_headers=headers, max_size=32 << 20) as up:
            await self.emit('status', text='sideband connected')

            async def app_to_voice():
                async for raw in downstream:
                    await up.send(raw)

            async def voice_to_app():
                async for raw in up:
                    try:
                        e = json.loads(raw)
                    except (ValueError, TypeError):
                        await downstream.send(raw)
                        continue
                    if not isinstance(e, dict):
                        await downstream.send(raw)
                        continue
                    try:
                        kind = str(e.get('type', ''))
                        turn = e.get('turn') if isinstance(e.get('turn'), dict) else {}
                        item = e.get('item') if isinstance(e.get('item'), dict) else {}
                        if kind not in ('session.input_audio.append', 'session.output_audio.delta'):
                            self.kinds[kind] = self.kinds.get(kind, 0) + 1
                            details = turn.get('status_details')
                            await self.emit('event', kind=kind, role=turn.get('role') or item.get('role'),
                                            status=turn.get('status'),
                                            reason=details.get('reason') if isinstance(details, dict) else None,
                                            keys=sorted(e.keys()), turnKeys=sorted(turn.keys()))
                        if kind == 'input_transcript.added':
                            self.user += str(item.get('text', ''))
                            await self.emit('user_transcript', text=self.user)
                        elif kind == 'output_transcript.added':
                            self.out += str(item.get('text', ''))
                            await self.emit('voice_transcript', text=self.out)
                    except Exception as error:
                        print('relay parse error', type(error).__name__, error, flush=True)
                    if kind in ('delegation.created', 'session.delegation.created'):
                        item = e.get('item', {})
                        ident = item.get('id') or e.get('delegation', {}).get('id')
                        if ident:
                            await up.send(json.dumps({'type': 'delegation.context.append', 'delegation_item_id': ident,
                                                      'channel': 'commentary', 'content': [{'type': 'input_text',
                                                      'text': 'このテストでは調べものはできません。自分の知識で短く答えてください。'}]}))
                        continue
                    await downstream.send(raw)

            pair = [asyncio.create_task(app_to_voice()), asyncio.create_task(voice_to_app())]
            try:
                done, _ = await asyncio.wait(pair, return_when=asyncio.FIRST_COMPLETED)
                for t in done:
                    if t.exception():
                        print('relay ended', time.strftime('%H:%M:%S'), type(t.exception()).__name__, t.exception(), flush=True)
            finally:
                for t in pair:
                    t.cancel()

    async def run(self, offer):
        env = dict(os.environ)
        env.pop('OPENAI_API_KEY', None)
        async with serve(self.relay, '127.0.0.1', 0, max_size=32 << 20) as relay:
            port = relay.sockets[0].getsockname()[1]
            self.voice = await Client(['-c', 'experimental_realtime_webrtc_call_base_url="https://chatgpt.com/backend-api/wham"',
                                       '-c', f'experimental_realtime_ws_base_url="http://127.0.0.1:{port}/v1"'], env).start()
            a = await self.voice.call('account/read', {'refreshToken': False})
            assert a['result']['account']['type'] == 'chatgpt'
            (ROOT / 'work').mkdir(exist_ok=True)
            t = await self.voice.call('thread/start', {'ephemeral': True, 'cwd': str(ROOT / 'work'), 'approvalPolicy': 'never',
                                                        'sandbox': 'read-only', 'model': 'gpt-6-luna'})
            self.tid = t['result']['thread']['id']
            await self.voice.call('thread/realtime/start', {
                'threadId': self.tid, 'version': 'v3', 'outputModality': 'audio', 'includeStartupContext': False,
                'clientManagedHandoffs': True, 'delegationAckFiller': False, 'prompt': PROMPT,
                **({'voice': VOICE} if VOICE else {}),
                'transport': {'type': 'webrtc', 'sdp': offer}})
            await self.voice.until(lambda e: e.get('method') in ['thread/realtime/sdp', 'thread/realtime/error'], 25)
            e = next((e for e in self.voice.events if e.get('method') == 'thread/realtime/sdp'), None)
            if not e:
                err = next((e for e in self.voice.events if e.get('method') == 'thread/realtime/error'), {})
                raise RuntimeError('no SDP answer: ' + json.dumps(err.get('params', {}))[:300])
            await self.emit('answer', sdp=e['params']['sdp'])
            await self.emit('status', text='gpt-live-1-codex ready')
            async for raw in self.socket:
                if json.loads(raw).get('type') == 'stop':
                    break
                if any(x.get('method') == 'turn/started' for x in self.voice.events):
                    await self.emit('event', kind='builtin_turn_started')

    async def close(self):
        print('sideband kinds', json.dumps(self.kinds), flush=True)
        if self.voice:
            if self.tid:
                try:
                    await self.voice.call('thread/realtime/stop', {'threadId': self.tid})
                except Exception:
                    pass
            await self.voice.close()


async def main():
    token = secrets.token_urlsafe(24)
    global VOICE
    args = [x for x in sys.argv[1:] if not x.startswith('--voice=')]
    VOICE = next((x.split('=', 1)[1] for x in sys.argv[1:] if x.startswith('--voice=')), None)
    host = args[0] if len(args) > 0 else '127.0.0.1'
    port = int(args[1]) if len(args) > 1 else 0
    busy = False

    async def handler(ws):
        nonlocal busy
        u = urlsplit(ws.request.path)
        if u.path != '/live' or parse_qs(u.query).get('token') != [token] or busy:
            await ws.close(1008, 'unauthorized or busy')
            return
        busy = True
        s = Session(ws)
        try:
            req = json.loads(await asyncio.wait_for(ws.recv(), 30))
            assert req['type'] == 'start'
            await s.run(req['sdp'])
        except Exception as error:
            await s.emit('error', text=f'{type(error).__name__}: {error}'[:300])
        finally:
            await s.close()
            busy = False

    async with serve(handler, host, port, max_size=4 << 20) as server:
        bound = server.sockets[0].getsockname()[1]
        control = ROOT / 'work/live-control.json'
        control.write_text(json.dumps({'url': f'ws://{host}:{bound}/live?token={token}'}))
        control.chmod(0o600)
        print('live control server ready (loopback)', flush=True)
        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            loop.add_signal_handler(sig, stop.set)
        try:
            await stop.wait()
        finally:
            control.unlink(missing_ok=True)


if __name__ == '__main__':
    asyncio.run(main())
