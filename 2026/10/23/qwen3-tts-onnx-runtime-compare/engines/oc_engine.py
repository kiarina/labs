"""onnx-community/Qwen3-TTS-12Hz-1.7B-Base on ONNX Runtime.

The generation follows the port's own `inference.py` (Apache-2.0, pinned commit in download.py): the talker with a KV
cache (`talker_cache.onnx`, prefill = empty past), the causal teacher-forced code predictor called 15 times per frame,
`residual_embed.onnx` for the next talker input, and the same numpy sampling. Two configurations:

- `published`: as `inference.py` does it. Non-streaming prompt layout (all text over codec pad, then the reference codes
  over text pad), the reference encoded in independent 1 s windows (each padded to 1 s), and the waveform decoded in
  independent 25-frame chunks.
- `matched`: qwen-tts 0.1.1's default prompt layout (`non_streaming_mode=False`, as the MLX baseline), the reference
  encoded with left context and trimmed to its real length, and the waveform decoded with left context. See README.

Providers: `cpu` (all CPU EP), `coreml` (the codec on CoreML's EP, the rest on CPU; CoreML rejects the talker and the code
predictor), `cuda` (everything on CUDA's EP from the port's `cuda_<precision>` export, with the talker's KV cache kept on
the GPU through IOBinding instead of copying 56 tensors to and from the host every step).
"""

from __future__ import annotations

import json
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
import soundfile as sf
from transformers import AutoTokenizer

from download import onnx_community, qwen_17b

from .common import REFERENCE_TEXT, SAMPLE_RATE, Synthesis, reference_wav

N_GROUPS = 16
SAMPLES_PER_FRAME = 1920  # 24 kHz / 12.5 Hz
DEC_FRAMES = 25  # tok_decoder is exported at a fixed 25 frames
ENC_SAMPLES = 24_000  # tok_encoder is exported at a fixed 1 s
_DTYPES = {"tensor(float)": np.float32, "tensor(float16)": np.float16, "tensor(int64)": np.int64}


def _sample(logits, top_k, top_p, temperature, rng):
    logits = logits.astype(np.float64) / max(temperature, 1e-6)
    if top_k:
        k = min(top_k, logits.shape[-1])
        kth = np.partition(logits, -k)[-k]
        logits = np.where(logits < kth, -np.inf, logits)
    logits -= logits.max()
    probs = np.exp(logits)
    probs /= probs.sum()
    if top_p < 1.0:
        order = np.argsort(probs)[::-1]
        keep = order[: np.searchsorted(np.cumsum(probs[order]), top_p) + 1]
        mask = np.zeros_like(probs)
        mask[keep] = probs[keep]
        probs = mask / mask.sum()
    return int(rng.choice(len(probs), p=probs))


class _Session:
    """Casts inputs to what the graph expects (the fp16 exports take float16) and float16 outputs back to float32."""

    def __init__(self, session: ort.InferenceSession) -> None:
        self.session = session
        self.types = {i.name: _DTYPES[i.type] for i in session.get_inputs()}

    def cast(self, feed: dict) -> dict:
        return {k: np.asarray(v).astype(self.types[k], copy=False) for k, v in feed.items()}

    def run(self, feed: dict, keep=()) -> list:
        """Outputs as float32, except the indices in `keep` (the KV cache stays in the graph's own dtype)."""
        out = self.session.run(None, self.cast(feed))
        keep = set(keep)
        return [o if i in keep or o.dtype != np.float16 else o.astype(np.float32) for i, o in enumerate(out)]


class Engine:
    def __init__(
        self,
        precision: str = "int4",
        mode: str = "matched",
        provider: str = "cpu",
        threads: int = 0,
        decoder_context: int = 12,
        encoder_context: int = 6,
        no_spin: bool = True,
    ) -> None:
        self.no_spin = no_spin
        self.precision, self.mode, self.provider, self.threads = precision, mode, provider, threads
        self.decoder_context = decoder_context if mode == "matched" else 0
        self.encoder_context = encoder_context
        self.device = "cuda" if provider == "cuda" else "cpu"
        self.name = (
            f"oc-1.7b-{precision}-{mode}"
            + (f"-{provider}" if provider != "cpu" else "")
            + (f"-t{threads}" if threads else "")
            + ("" if no_spin else "-spin")
        )
        self.description = (
            f"onnx-community 1.7B Base {self.device}_{precision}, {mode}, ONNX Runtime {ort.__version__} "
            + {"cpu": "CPU EP", "coreml": "CPU EP (codec on CoreML EP)", "cuda": "CUDA EP"}[provider]
            + (f", {threads} threads" if threads else "")
            + ("" if no_spin else ", spinning thread pools")
        )

    # ── loading ──────────────────────────────────────────────────────────────
    def load(self) -> None:
        root = Path(onnx_community(self.precision, self.device)) / f"{self.device}_{self.precision}"
        options = ort.SessionOptions()
        options.log_severity_level = 3
        if self.threads:
            options.intra_op_num_threads = self.threads
        # Eight sessions each own a thread pool; spinning pools steal cores from the one that is running (README).
        options.add_session_config_entry("session.intra_op.allow_spinning", "0" if self.no_spin else "1")
        cpu = ["CPUExecutionProvider"]
        # CoreML's EP rejects the talker and the code predictor (README, components.py); only the codec goes there.
        coreml = [("CoreMLExecutionProvider", {"ModelFormat": "MLProgram", "MLComputeUnits": "ALL"}), "CPUExecutionProvider"]
        cuda = ["CUDAExecutionProvider", "CPUExecutionProvider"]

        def session(name):
            if self.provider == "cuda":
                providers = cuda
            else:
                providers = coreml if self.provider == "coreml" and name in ("tok_decoder", "tok_encoder") else cpu
            return _Session(ort.InferenceSession(str(root / f"{name}.onnx"), options, providers=providers))

        self.text_embed, self.codec_embed = session("text_embed"), session("codec_embed")
        self.talker, self.predictor = session("talker_cache"), session("code_predictor")
        self.residual, self.speaker = session("residual_embed"), session("speaker_encoder")
        self.encoder, self.decoder = session("tok_encoder"), session("tok_decoder")
        inputs = self.talker.session.get_inputs()
        self.past_names = [i.name for i in inputs][3:]
        self.past_shape = inputs[3].shape  # [1, kv_heads, past, head_dim]
        self.past_dtype = _DTYPES[inputs[3].type]
        self.out_names = [o.name for o in self.talker.session.get_outputs()]
        self.providers = {
            name: getattr(self, attr).session.get_providers()[0]
            for name, attr in [("talker_cache", "talker"), ("code_predictor", "predictor"), ("tok_decoder", "decoder")]
        }

        tts_dir = qwen_17b()
        self.cfg = json.loads((Path(tts_dir) / "config.json").read_text())
        self.tok = AutoTokenizer.from_pretrained(tts_dir)

        started = time.perf_counter()
        self._prepare_reference()
        self.reference_seconds = time.perf_counter() - started

    def _ids(self, text):
        return np.asarray(self.tok(text, return_tensors="np")["input_ids"], np.int64).reshape(1, -1)

    def embed_text(self, ids):
        return self.text_embed.run({"text_ids": np.asarray(ids, np.int64)})[0]

    def embed_codec(self, ids):
        return self.codec_embed.run({"codec_ids": np.asarray(ids, np.int64)})[0]

    def step_embed(self, codes16):
        return self.residual.run({"codec_ids": np.asarray(codes16, np.int64)})[0]

    # ── reference ────────────────────────────────────────────────────────────
    def encode_reference(self, wav: np.ndarray) -> np.ndarray:
        """wav [L] at 24 kHz → codes [T, 16]."""

        def run(window):
            window = np.pad(window, (0, ENC_SAMPLES - len(window)))
            return self.encoder.run({"audio": window.reshape(1, 1, -1)})[0][0]

        if self.mode == "published":  # inference.py's encode_chunked: independent 1 s windows, each padded to 1 s
            return np.concatenate([run(wav[s : s + ENC_SAMPLES]) for s in range(0, max(len(wav), 1), ENC_SAMPLES)]).astype(np.int64)
        # Windows of 12 frames (0.96 s) of new audio, each preceded by `encoder_context` frames of real audio; keep only the
        # frames of the new part, then trim to the frames the audio actually covers.
        total = int(np.ceil(len(wav) / SAMPLES_PER_FRAME))
        ctx = self.encoder_context
        step = 12 - ctx
        codes = []
        for frame in range(0, total, step):
            start = max(frame - ctx, 0)
            out = run(wav[start * SAMPLES_PER_FRAME : start * SAMPLES_PER_FRAME + ENC_SAMPLES])
            codes.append(out[frame - start : frame - start + step])
        return np.concatenate(codes)[:total].astype(np.int64)

    def _prepare_reference(self) -> None:
        wav, rate = sf.read(reference_wav(), dtype="float32")
        assert rate == SAMPLE_RATE
        self.ref_codes = self.encode_reference(wav)
        hidden = self.cfg["talker_config"]["hidden_size"]
        self.xvector = self.speaker.run({"audio": wav[None]})[0].reshape(1, 1, hidden)
        self.ref_ids = self._ids(f"<|im_start|>assistant\n{REFERENCE_TEXT}<|im_end|>\n")[:, 3:-2]
        self.ref_step_embeds = self.step_embed(self.ref_codes)[None]  # [1, T_ref, H]
        cfg, tc = self.cfg, self.cfg["talker_config"]
        spec = self.embed_text([[cfg["tts_bos_token_id"], cfg["tts_eos_token_id"], cfg["tts_pad_token_id"]]])
        self.bos_e, self.eos_e, self.pad_e = spec[:, 0:1], spec[:, 1:2], spec[:, 2:3]
        prefill = [[tc["codec_think_id"], tc["codec_think_bos_id"], tc["codec_language_id"]["japanese"], tc["codec_think_eos_id"]]]
        codec_input = np.concatenate(
            [self.embed_codec(prefill), self.xvector, self.embed_codec([[tc["codec_pad_id"], tc["codec_bos_id"]]])], axis=1
        )
        role = self.embed_text(self._ids("<|im_start|>assistant\n")[:, :3])
        pad_block = np.concatenate([np.repeat(self.pad_e, codec_input.shape[1] - 2, axis=1), self.bos_e], axis=1)
        self.prefix = np.concatenate([role, pad_block + codec_input[:, :-1]], axis=1)
        self.codec_bos_e = self.embed_codec([[tc["codec_bos_id"]]])

    def prompt(self, text: str):
        """Talker prefill and the per-step trailing text for the voice-clone (ICL) prompt."""
        tc = self.cfg["talker_config"]
        text_id = self._ids(f"<|im_start|>assistant\n{text}<|im_end|>\n<|im_start|>assistant\n")[:, 3:-5]
        text_embed = np.concatenate([self.embed_text(np.concatenate([self.ref_ids, text_id], axis=1)), self.eos_e], axis=1)
        codec_embed = np.concatenate([self.codec_bos_e, self.ref_step_embeds], axis=1)
        t_len, c_len = text_embed.shape[1], codec_embed.shape[1]
        if self.mode == "published":  # non_streaming_mode=True
            icl = np.concatenate([text_embed + self.embed_codec([[tc["codec_pad_id"]] * t_len]), codec_embed + self.pad_e], axis=1)
            trailing = self.pad_e[0]  # [1, H]
        elif t_len > c_len:  # qwen-tts default, non_streaming_mode=False
            icl, trailing = text_embed[:, :c_len] + codec_embed, text_embed[0, c_len:]
        else:
            pad = np.repeat(self.pad_e, c_len - t_len, axis=1)
            icl, trailing = np.concatenate([text_embed, pad], axis=1) + codec_embed, self.pad_e[0]
        return np.concatenate([self.prefix, icl], axis=1), trailing

    # ── generation ───────────────────────────────────────────────────────────
    def _talker(self, embeds, start, past):
        cur = embeds.shape[1]
        feed = {
            "inputs_embeds": embeds,
            "position_ids": np.broadcast_to(np.arange(start, start + cur), (3, 1, cur)).astype(np.int64),
            "attention_mask": np.ones((1, start + cur), np.int64),
        }
        if self.provider != "cuda":
            feed.update(zip(self.past_names, past))
            out = self.talker.run(feed, keep=range(2, len(self.out_names)))
            return out[0], out[1], out[2:]
        # CUDA: past/present stay on the GPU as OrtValues; only logits and the hidden state come back.
        session = self.talker.session
        binding = session.io_binding()
        for name, value in self.talker.cast(feed).items():
            binding.bind_cpu_input(name, value)
        for name, value in zip(self.past_names, past):
            binding.bind_ortvalue_input(name, value)
        binding.bind_output(self.out_names[0], "cpu")
        binding.bind_output(self.out_names[1], "cpu")
        for name in self.out_names[2:]:
            binding.bind_output(name, "cuda")
        session.run_with_iobinding(binding)
        out = binding.get_outputs()
        return out[0].numpy().astype(np.float32), out[1].numpy().astype(np.float32), out[2:]

    def _decode(self, codes, start, end):
        """Waveform of frames [start, end) through the fixed 25-frame decoder, with up to `decoder_context` frames before."""
        left = max(start - self.decoder_context, 0)
        window = codes[left:end]
        n = len(window)
        if n < DEC_FRAMES:  # pad the tail by repetition, as inference.py does; the decoder is causal (README)
            window = window[np.arange(DEC_FRAMES) % n]
        wav = self.decoder.run({"audio_codes": window[None]})[0].reshape(-1)
        return wav[(start - left) * SAMPLES_PER_FRAME : n * SAMPLES_PER_FRAME]

    def synthesize(self, text: str, seed: int, max_frames: int = 600) -> Synthesis:
        tc = self.cfg["talker_config"]
        vocab, eos = tc["vocab_size"], tc["codec_eos_token_id"]
        suppress = np.array([i for i in range(vocab - 1024, vocab) if i != eos], np.int64)
        rng = np.random.default_rng(seed)
        new_per_call = DEC_FRAMES - self.decoder_context
        started = time.perf_counter()
        talker_in, trailing = self.prompt(text)
        past = [np.zeros((1, self.past_shape[1], 0, self.past_shape[3]), self.past_dtype) for _ in self.past_names]
        if self.provider == "cuda":
            past = [ort.OrtValue.ortvalue_from_numpy(p, "cuda", 0) for p in past]
        logits, hidden, past = self._talker(talker_in, 0, past)
        total = talker_in.shape[1]
        frames, previous, chunks, arrivals, decoded = [], [], [], [], 0
        timing = {"prefill": time.perf_counter() - started, "talker": 0.0, "predictor": 0.0, "decoder": 0.0}
        for step in range(max_frames):
            first = logits[0, -1].astype(np.float64).copy()
            first[suppress] = -np.inf
            if previous:  # repetition penalty 1.05 over all generated first codes, as generation_config.json
                idx = np.array(sorted(set(previous)))
                first[idx] = np.where(first[idx] < 0, first[idx] * 1.05, first[idx] / 1.05)
            code0 = _sample(first, 50, 1.0, 0.9, rng)
            if code0 == eos:
                break
            previous.append(code0)
            t0 = time.perf_counter()
            th = hidden[0, -1][None]
            codes16 = np.zeros((1, N_GROUPS), np.int64)
            codes16[0, 0] = code0
            for j in range(1, N_GROUPS):
                gl = self.predictor.run({"talker_hidden": th, "codec_ids": codes16})[0]
                codes16[0, j] = _sample(gl[0, j - 1], 50, 1.0, 0.9, rng)
            t1 = time.perf_counter()
            frames.append(codes16[0].copy())
            nxt = self.step_embed(codes16)[:, None] + (trailing[step] if step < len(trailing) else self.pad_e[0])[None]
            logits, hidden, past = self._talker(nxt, total, past)
            total += 1
            t2 = time.perf_counter()
            timing["predictor"] += t1 - t0
            timing["talker"] += t2 - t1
            if len(frames) - decoded >= new_per_call:
                chunks.append(self._decode(np.stack(frames), decoded, decoded + new_per_call))
                decoded += new_per_call
                arrivals.append((time.perf_counter() - started, len(chunks[-1]) / SAMPLE_RATE))
                timing["decoder"] += time.perf_counter() - t2
        if len(frames) > decoded:
            t2 = time.perf_counter()
            chunks.append(self._decode(np.stack(frames), decoded, len(frames)))
            arrivals.append((time.perf_counter() - started, len(chunks[-1]) / SAMPLE_RATE))
            timing["decoder"] += time.perf_counter() - t2
        elapsed = time.perf_counter() - started
        audio = np.concatenate(chunks) if chunks else np.zeros(0, np.float32)
        return Synthesis(audio, elapsed, arrivals, frames=len(frames), extra={"timing": timing, "prefill_tokens": int(talker_in.shape[1])})

    def memory(self) -> dict:
        return {
            "reference_seconds": self.reference_seconds,
            "reference_frames": int(len(self.ref_codes)),
            "providers": self.providers,
        }
