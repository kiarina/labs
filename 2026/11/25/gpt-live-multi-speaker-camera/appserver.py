"""Minimal JSON-RPC client for `codex app-server` over stdio (copied from the codex-gpt-live-1-1 lab)."""
import asyncio, json, time


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


