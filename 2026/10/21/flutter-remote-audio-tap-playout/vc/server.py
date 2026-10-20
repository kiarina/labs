#!/usr/bin/env python3
"""Loopback streaming MeanVC2 service for the playout slot (slot mode 3).

Frames in both directions: 1 byte type, 4 byte little-endian length, payload.
Client -> server: b'P' PCM16 48 kHz mono (received voice), b'R' reset, b'Q' stats,
b'T' target voice (an audio file's bytes, or b'asset:speaker1' / b'asset:speaker2').
Server -> client: b'P' PCM16 48 kHz mono (converted voice), b'S' stats JSON,
b'T' target result JSON (seconds, embedding time, or error).
One client at a time. Conversion runs in a worker thread so the event loop keeps
reading; chunks are processed in arrival order.
"""
import argparse, asyncio, io, json, struct, threading, time, queue
from pathlib import Path
import numpy as np
import soxr
import librosa

from stream_vc import StreamingVC, CHUNK

ROOT = Path(__file__).resolve().parents[1]
SPEAKERS = {  # utterance spans of the shared asset
    'speaker1': [(0.000, 1.851), (4.737, 7.317), (9.677, 11.834)],
    'speaker2': [(1.851, 4.737), (7.317, 9.677), (11.834, 14.171)],
}


def target_audio(spec) -> np.ndarray:
    """spec: 'asset:speaker1|2', a file path, or the bytes of an audio file."""
    if isinstance(spec, str) and spec.startswith('asset:'):
        audio, _ = librosa.load(ROOT.parents[3] / 'tests/assets/mp3/conversation_2speaker_14s_16k.mp3', sr=16000, mono=True)
        return np.concatenate([audio[int(a * 16000):int(b * 16000)] for a, b in SPEAKERS[spec[6:]]])
    audio, _ = librosa.load(io.BytesIO(spec) if isinstance(spec, bytes) else spec, sr=16000, mono=True)
    return audio


class Level:
    """Match the converted voice's loudness to the received voice and keep it
    below full scale. MeanVC2 output was ~5 dB louder and clipped in the app,
    which was heard as distortion (owner, 2026-10-20)."""
    def __init__(self):
        self.e_in = self.e_out = 1e-6
        self.gain = 1.0
        self.voiced = False
        self.gains = []

    SPEECH = 10 ** (-45 / 10)  # input mean square above -45 dBFS counts as voice

    def track_input(self, x: np.ndarray):
        # Only voiced input moves the estimate; between replies the converter
        # still emits a low noise floor, which drove the gain to its floor and
        # softened the start of the next reply (2026-10-20, mac-vc-himari-2).
        self.voiced = len(x) and float(np.mean(x * x)) > self.SPEECH
        if self.voiced:
            self.e_in = 0.9 * self.e_in + 0.1 * float(np.mean(x * x))

    def apply(self, y: np.ndarray) -> np.ndarray:
        if not len(y):
            return y
        if getattr(self, 'voiced', False):
            self.e_out = 0.9 * self.e_out + 0.1 * float(np.mean(y * y))
            target = float(np.clip(np.sqrt(self.e_in / max(self.e_out, 1e-9)), 0.25, 1.5))
            self.gain = 0.9 * self.gain + 0.1 * target
            self.gains.append(self.gain)
        y = y * self.gain
        knee = 0.7  # soft limiter: linear below 0.7, approaches 0.9
        mag = np.abs(y)
        over = mag > knee
        y[over] = np.sign(y[over]) * (knee + 0.2 * np.tanh((mag[over] - knee) / 0.2))
        return y


class Session:
    def __init__(self, vc: StreamingVC):
        self.level = Level()
        self.vc = vc
        self.down = soxr.ResampleStream(48000, 16000, 1, dtype='float32')
        self.up = soxr.ResampleStream(16000, 48000, 1, dtype='float32')
        self.pending = np.zeros(0, np.float32)
        self.times = []
        self.in_samples = self.out_samples = 0
        vc.reset()

    def feed(self, pcm48: bytes) -> bytes:
        x = np.frombuffer(pcm48, '<i2').astype(np.float32) / 32768
        self.in_samples += len(x)
        self.pending = np.concatenate([self.pending, self.down.resample_chunk(x)])
        out = []
        while len(self.pending) >= CHUNK:
            chunk, self.pending = self.pending[:CHUNK], self.pending[CHUNK:]
            self.level.track_input(chunk)
            t0 = time.perf_counter()
            y = self.vc.process(chunk)
            self.times.append((time.perf_counter() - t0) * 1000)
            if len(y):
                out.append(self.up.resample_chunk(self.level.apply(y)))
        if not out:
            return b''
        y48 = np.concatenate(out)
        self.out_samples += len(y48)
        return (np.clip(y48, -1, 1) * 32767).astype('<i2').tobytes()

    def stats(self):
        t = np.array(self.times) if self.times else np.zeros(1)
        return {'chunks': len(self.times), 'p50Ms': float(np.percentile(t, 50)), 'p95Ms': float(np.percentile(t, 95)),
                'p99Ms': float(np.percentile(t, 99)), 'maxMs': float(t.max()), 'deadlineMisses': int(np.sum(t > CHUNK / 16)),
                'inSamples48k': self.in_samples, 'outSamples48k': self.out_samples, 'levelGain': round(self.level.gain, 3),
                'levelGainP10P50P90': [round(float(np.percentile(self.level.gains, q)), 3) for q in (10, 50, 90)] if self.level.gains else None,
                'steps': self.vc.steps}


async def main():
    p = argparse.ArgumentParser()
    p.add_argument('--port', type=int, default=18810)
    p.add_argument('--threads', type=int, default=1)
    p.add_argument('--model', default='120ms')
    p.add_argument('--steps', type=int, default=2)
    p.add_argument('--target', default='asset:speaker2')
    p.add_argument('--stats', type=Path, help='append per-session stats JSON lines here')
    a = p.parse_args()
    vc = StreamingVC(threads=a.threads, model=a.model, steps=a.steps)
    emb_s = vc.set_target(target_audio(a.target))
    for _ in range(3):
        vc.process(np.zeros(CHUNK, np.float32))
    print(json.dumps({'ready': True, 'port': a.port, 'loadSeconds': round(vc.load_seconds, 2), 'targetEmbeddingSeconds': round(emb_s, 3),
                      'model': a.model, 'steps': a.steps, 'threads': a.threads,
                      'target': a.target if a.target.startswith('asset:') else 'file'}), flush=True)

    async def handle(reader, writer):
        session = Session(vc)
        work: queue.Queue = queue.Queue()
        loop = asyncio.get_running_loop()
        out_q: asyncio.Queue = asyncio.Queue()

        def worker():
            while (item := work.get()) is not None:
                kind, payload = item
                if kind == b'R':
                    nonlocal_session[0] = Session(vc)
                elif kind == b'P':
                    data = nonlocal_session[0].feed(payload)
                    if data:
                        loop.call_soon_threadsafe(out_q.put_nowait, (b'P', data))
                elif kind == b'T':
                    try:
                        spec = payload.decode() if payload.startswith(b'asset:') else payload
                        audio = target_audio(spec)
                        if len(audio) < 16000:
                            raise ValueError('target shorter than 1 second')
                        audio = audio[:16000 * 30]  # cap the reference at 30 s
                        took = vc.set_target(audio)
                        nonlocal_session[0] = Session(vc)
                        reply = {'ok': True, 'seconds': round(len(audio) / 16000, 2), 'embeddingSeconds': round(took, 3),
                                 'target': spec if isinstance(spec, str) else 'file'}
                    except Exception as error:  # noqa: BLE001 - reported to the app
                        reply = {'ok': False, 'error': f'{type(error).__name__}: {error}'[:200]}
                    print(json.dumps({'target': reply}), flush=True)
                    loop.call_soon_threadsafe(out_q.put_nowait, (b'T', json.dumps(reply).encode()))
                elif kind == b'Q':
                    loop.call_soon_threadsafe(out_q.put_nowait, (b'S', json.dumps(nonlocal_session[0].stats()).encode()))

        nonlocal_session = [session]
        thread = threading.Thread(target=worker, daemon=True)
        thread.start()

        async def sender():
            while True:
                kind, data = await out_q.get()
                writer.write(kind + struct.pack('<I', len(data)) + data)
                await writer.drain()

        send_task = asyncio.create_task(sender())
        try:
            while True:
                head = await reader.readexactly(5)
                kind, n = head[:1], struct.unpack('<I', head[1:])[0]
                work.put((kind, await reader.readexactly(n) if n else b''))
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            work.put(None)
            thread.join(5)
            send_task.cancel()
            stats = nonlocal_session[0].stats()
            print(json.dumps({'session': stats}), flush=True)
            if a.stats:
                with a.stats.open('a') as f:
                    f.write(json.dumps(stats) + '\n')
            writer.close()

    server = await asyncio.start_server(handle, '127.0.0.1', a.port)
    async with server:
        await server.serve_forever()


if __name__ == '__main__':
    asyncio.run(main())
