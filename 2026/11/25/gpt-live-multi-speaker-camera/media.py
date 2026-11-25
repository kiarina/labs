"""Audio playout over WebRTC and speaker notes (Silero VAD + ECAPA-TDNN), copied from the gpt-live-multi-speaker-notes lab."""
import asyncio, fractions, time
import av
import numpy as np
import onnxruntime as ort
from aiortc import MediaStreamTrack
from speaker import MODELS
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


