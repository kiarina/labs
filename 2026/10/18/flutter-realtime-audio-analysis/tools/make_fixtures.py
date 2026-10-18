"""Python reference fixtures for the Dart port of kiarina-agi-audio.

Runs the real kiarina-agi-audio code paths the way kiarina-agi-data-builder's
audio analysis does (FileAudioSource -> STT consumer + Ambient consumer) on
work/conversation_16k.wav, and records what each stage produced. Recording is
done with observe-only wrappers that call the original methods unchanged.

Outputs:
  fixtures/{input,vad,scd,ecapa,yamnet,clap}.json   (committed, small)
  work/fixtures-bin/*.f32                            (little-endian float32, gitignored)

Usage (from the lab directory):
  uv run --project tools python tools/make_fixtures.py
"""

import asyncio
import functools
import hashlib
import json
import os
import sys
from pathlib import Path
from typing import Any

import numpy as np
import soundfile as sf

LAB_DIR = Path(__file__).resolve().parent.parent
WAV_PATH = LAB_DIR / "work" / "conversation_16k.wav"
FIXTURES_DIR = LAB_DIR / "fixtures"
BIN_DIR = LAB_DIR / "work" / "fixtures-bin"

# Keep downloaded models inside the lab (gitignored) unless the caller overrides it.
os.environ.setdefault(
    "KIARINA_UTILS_APP_USER_CACHE_DIR", str(LAB_DIR / "models" / "kiarina-cache")
)

# Imports after the cache override so kiarina picks it up.
from kiarina.agi.audio_consumer import audio_consumer_registry  # noqa: E402
from kiarina.agi.audio_embedding_provider_impl.clap_onnx._models import (  # noqa: E402
    clap_onnx_audio_embedding_provider as clap_mod,
)
from kiarina.agi.audio_source import audio_source_registry  # noqa: E402
from kiarina.agi.audio_tagging_provider_impl.yamnet._models import (  # noqa: E402
    yamnet_audio_tagging_provider as yamnet_mod,
)
from kiarina.agi.embedding import calc_cosine_similarity  # noqa: E402
from kiarina.agi.run_context import RunContext  # noqa: E402
from kiarina.agi.scd_model._models import scd_model as scd_model_mod  # noqa: E402
from kiarina.agi.speaker_change_detector._models import (  # noqa: E402
    speaker_change_detector as scd_det_mod,
)
from kiarina.agi.voice_detector._models import voice_detector as vd_mod  # noqa: E402
from kiarina.utils.app import configure as configure_app  # noqa: E402

SAMPLE_RATE = 16_000
CHUNK_SIZE = 512

# Same specifiers as kiarina-agi-data-builder's AudioFileInfoBuilderSettings,
# except asr_model=mock so no ASR service is called (ASR text is not a fixture).
AUDIO_SOURCE = f"file?sample_rate={SAMPLE_RATE}&start_timestamp=0.0&chunk_size={CHUNK_SIZE}"
STT_CONSUMER = "stt?diarization_enabled=true&asr_model=mock"
AMBIENT_CONSUMER = "ambient?window_seconds=10.0&top_k=3"


def r6(value: float) -> float:
    return float(f"{float(value):.6g}")


def r6list(values: Any) -> Any:
    array = np.asarray(values, dtype=np.float64)

    if array.ndim == 0:
        return r6(array)

    return [r6list(v) for v in array] if array.ndim > 1 else [r6(v) for v in array]


def sha256_f32(values: Any) -> str:
    return hashlib.sha256(
        np.ascontiguousarray(values, dtype="<f4").tobytes()
    ).hexdigest()


def save_bin(name: str, values: Any) -> dict[str, Any]:
    array = np.ascontiguousarray(values, dtype="<f4")
    path = BIN_DIR / name
    path.write_bytes(array.tobytes())
    return {
        "path": str(path.relative_to(LAB_DIR)),
        "shape": list(array.shape),
        "sha256": sha256_f32(array),
    }


def write_json(name: str, data: Any) -> None:
    path = FIXTURES_DIR / name
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n")
    print(f"wrote {path.relative_to(LAB_DIR)} ({path.stat().st_size} bytes)")


class Recorder:
    def __init__(self) -> None:
        self.chunks: list[dict[str, Any]] = []
        self.voices: list[dict[str, Any]] = []
        self.scd_results: list[Any] = []
        self.scd_speeches: list[list[Any]] = []
        self.yamnet_scores: list[np.ndarray] = []
        self.clap_inputs: list[dict[str, Any]] = []


def install_observers(rec: Recorder) -> None:
    """Wrap methods so their inputs/outputs are recorded; behaviour is unchanged."""

    vd_cls = vd_mod.VoiceDetector
    orig_detect = vd_cls.detect
    orig_emit = vd_cls._emit

    @functools.wraps(orig_detect)
    async def detect(self, samples, sample_rate, timestamp):  # type: ignore[no-untyped-def]
        start = self._cursor_samples
        result = await orig_detect(self, samples, sample_rate, timestamp)
        rec.chunks.append(
            {
                "start": start,
                "length": int(np.asarray(samples).shape[-1]),
                "timestamp": timestamp,
                "probability": result.probability,
                "is_voice": result.is_voice,
                "emitted_voice": result.voice is not None,
            }
        )
        return result

    @functools.wraps(orig_emit)
    def emit(self):  # type: ignore[no-untyped-def]
        buffer = [(start, len(chunk)) for start, _, chunk in self._voice_buffer]
        state = {
            "voice_start_samples": self._voice_start_samples,
            "last_voice_end_samples": self._last_voice_end_samples,
            "cursor_samples": self._cursor_samples,
        }
        voice = orig_emit(self)
        rec.voices.append({"voice": voice, "buffer": buffer, **state})
        return voice

    vd_cls.detect = detect  # type: ignore[method-assign]
    vd_cls._emit = emit  # type: ignore[method-assign]

    scd_cls = scd_model_mod.SCDModel
    orig_scd_predict = scd_cls.predict

    @functools.wraps(orig_scd_predict)
    async def scd_predict(self, samples, sample_rate):  # type: ignore[no-untyped-def]
        result = await orig_scd_predict(self, samples, sample_rate)
        rec.scd_results.append(result)
        return result

    scd_cls.predict = scd_predict  # type: ignore[method-assign]

    det_cls = scd_det_mod.SpeakerChangeDetector
    orig_det = det_cls.detect

    @functools.wraps(orig_det)
    async def det_detect(self, samples, sample_rate, timestamp):  # type: ignore[no-untyped-def]
        speeches = await orig_det(self, samples, sample_rate, timestamp)
        rec.scd_speeches.append(
            [(s.start_timestamp, s.end_timestamp, len(s.samples), s.speaker_index) for s in speeches]
        )
        return speeches

    det_cls.detect = det_detect  # type: ignore[method-assign]

    yam_cls = yamnet_mod.YamnetAudioTaggingProvider
    orig_invoke = yam_cls._invoke

    @functools.wraps(orig_invoke)
    def invoke(self, samples):  # type: ignore[no-untyped-def]
        scores = orig_invoke(self, samples)
        rec.yamnet_scores.append(np.array(scores, copy=True))
        return scores

    yam_cls._invoke = invoke  # type: ignore[method-assign]

    clap_cls = clap_mod.ClapOnnxAudioEmbeddingProvider
    orig_extract = clap_cls._extract_input_features

    @functools.wraps(orig_extract)
    def extract(self, samples):  # type: ignore[no-untyped-def]
        features, is_longer = orig_extract(self, samples)
        rec.clap_inputs.append(
            {
                "resampled": np.array(samples, dtype=np.float32, copy=True),
                "features": np.array(features, copy=True),
                "is_longer": np.array(is_longer, copy=True),
                "mel_filters": np.array(self.mel_filters, copy=True),
                "preprocessor_config": dict(self.preprocessor_config),
                "input_names": [i.name for i in self.session.get_inputs()],
            }
        )
        return features, is_longer

    clap_cls._extract_input_features = extract  # type: ignore[method-assign]


class _ReplayVADModel:
    """Feeds recorded Silero probabilities back to a VoiceDetector (no model call)."""

    def __init__(self, probabilities: list[float]) -> None:
        self._probabilities = list(probabilities)

    async def predict(self, samples: Any, sample_rate: int) -> float:
        return self._probabilities.pop(0)


# Extra VoiceDetector settings exercised on the same probabilities, because the
# default settings yield a single voice emitted only by flush() on this input.
VOICE_DETECTOR_VARIANTS = [
    {"threshold": 0.5, "min_silence_ms": 200, "voice_pad_ms": 300},
    {"threshold": 0.5, "min_silence_ms": 100, "voice_pad_ms": 100},
    {"threshold": 0.7, "min_silence_ms": 100, "voice_pad_ms": 0},
]


async def replay_voice_detector(
    chunks: list[Any], probabilities: list[float], settings: dict[str, Any]
) -> list[dict[str, Any]]:
    from kiarina.agi.voice_detector import VoiceDetectorSettings

    detector = vd_mod.VoiceDetector(
        _ReplayVADModel(probabilities),  # type: ignore[arg-type]
        VoiceDetectorSettings(**settings),
    )
    out: list[dict[str, Any]] = []

    def record(voice: Any, chunk_index: int | None) -> None:
        out.append(
            {
                "start_sample": round(voice.start_timestamp * SAMPLE_RATE),
                "end_sample": round(voice.end_timestamp * SAMPLE_RATE),
                "start_timestamp": r6(voice.start_timestamp),
                "end_timestamp": r6(voice.end_timestamp),
                "num_samples": int(len(voice.samples)),
                "samples_sha256": sha256_f32(voice.samples),
                "emitted_after_chunk_index": chunk_index,
            }
        )

    for index, chunk in enumerate(chunks):
        result = await detector.detect(chunk.samples, chunk.sample_rate, chunk.timestamp)

        if result.voice is not None:
            record(result.voice, index)

    if voice := detector.flush():
        record(voice, None)

    return out


async def run_pipeline() -> tuple[list[Any], list[Any], list[Any]]:
    configure_app("flutter-realtime-audio-analysis-fixtures", "labs")
    run_context = RunContext()
    stt = audio_consumer_registry.resolve(STT_CONSUMER, run_context=run_context)
    ambient = audio_consumer_registry.resolve(AMBIENT_CONSUMER, run_context=run_context)
    consumers = [stt, ambient]
    source = audio_source_registry.resolve(AUDIO_SOURCE)

    chunks: list[Any] = []
    stt_events: list[Any] = []
    ambient_events: list[Any] = []

    async with source.open(WAV_PATH):
        async for chunk in source.read():
            chunks.append(chunk)
            stt_events.extend(await stt.accept(chunk))
            ambient_events.extend(await ambient.accept(chunk))

    stt_events.extend(await stt.flush())
    ambient_events.extend(await ambient.flush())

    del consumers
    return chunks, stt_events, ambient_events


def main() -> None:
    FIXTURES_DIR.mkdir(parents=True, exist_ok=True)
    BIN_DIR.mkdir(parents=True, exist_ok=True)

    pcm, file_sr = sf.read(WAV_PATH, dtype="int16")
    assert file_sr == SAMPLE_RATE and pcm.ndim == 1, (file_sr, pcm.shape)
    wav = (pcm.astype(np.float32) / 32768.0).astype(np.float32)

    rec = Recorder()
    install_observers(rec)
    chunks, stt_events, ambient_events = asyncio.run(run_pipeline())

    # The FileAudioSource reads float32 via libsndfile, which is PCM16/32768.
    source_samples = np.concatenate([c.samples[0] for c in chunks])
    assert np.array_equal(source_samples, wav), "file source != PCM16/32768"

    write_json(
        "input.json",
        {
            "wav": str(WAV_PATH.relative_to(LAB_DIR)),
            "sample_rate": SAMPLE_RATE,
            "num_samples": int(len(wav)),
            "duration_s": r6(len(wav) / SAMPLE_RATE),
            "pcm16_sha256": hashlib.sha256(pcm.astype("<i2").tobytes()).hexdigest(),
            "float32_sha256": sha256_f32(wav),
            "float32_conversion": "int16 / 32768.0 (identical to soundfile dtype=float32)",
            "audio_source": AUDIO_SOURCE,
            "consumers": [STT_CONSUMER, AMBIENT_CONSUMER],
        },
    )

    # ---------------------------------------------------------------- VAD
    full = [c for c in rec.chunks if c["length"] == CHUNK_SIZE]
    tail = [c for c in rec.chunks if c["length"] != CHUNK_SIZE]
    voices_out = []
    emit_chunks = [i for i, c in enumerate(rec.chunks) if c["emitted_voice"]]

    for index, item in enumerate(rec.voices):
        voice = item["voice"]
        voices_out.append(
            {
                "index": index,
                "start_sample": round(voice.start_timestamp * SAMPLE_RATE),
                "end_sample": round(voice.end_timestamp * SAMPLE_RATE),
                "start_timestamp": r6(voice.start_timestamp),
                "end_timestamp": r6(voice.end_timestamp),
                "num_samples": int(len(voice.samples)),
                "samples_sha256": sha256_f32(voice.samples),
                "buffer_chunks": [[s, n] for s, n in item["buffer"]],
                "buffer_is_contiguous": all(
                    a[0] + a[1] == b[0] for a, b in zip(item["buffer"], item["buffer"][1:])
                ),
                "emitted_after_chunk_index": emit_chunks[index] if index < len(emit_chunks) else None,
                "emitted_by_flush": index >= len(emit_chunks),
            }
        )

    n_chunks, n_voices = len(rec.chunks), len(rec.voices)
    probabilities = [c["probability"] for c in rec.chunks]
    write_json(
        "vad.json",
        {
            "provider": "silero (SileroVADProvider via VADModel 'local')",
            "sample_rate": SAMPLE_RATE,
            "chunk_size": CHUNK_SIZE,
            "context_samples": 64,
            "num_chunks": len(rec.chunks),
            "num_full_chunks": len(full),
            "tail_chunk": (
                {"start": tail[0]["start"], "length": tail[0]["length"],
                 "probability": r6(tail[0]["probability"])} if tail else None
            ),
            "probabilities": [r6(c["probability"]) for c in rec.chunks],
            "voice_detector": {"threshold": 0.5, "min_silence_ms": 500, "voice_pad_ms": 300},
            "voices": voices_out,
            "voice_detector_variants": [
                {
                    "settings": settings,
                    "voices": asyncio.run(
                        replay_voice_detector(chunks, probabilities, settings)
                    ),
                }
                for settings in VOICE_DETECTOR_VARIANTS
            ],
            "variants_note": "Variants replay the recorded probabilities into a fresh "
            "VoiceDetector (rec.chunks probabilities are unrounded floats).",
        },
    )

    # The replays also pass through the observers; drop what they added.
    del rec.chunks[n_chunks:], rec.voices[n_voices:]

    # ---------------------------------------------------------------- SCD
    assert len(rec.scd_results) == len(rec.voices) == len(rec.scd_speeches)
    scd_out = []

    for index, (item, result, speeches) in enumerate(
        zip(rec.voices, rec.scd_results, rec.scd_speeches, strict=True)
    ):
        voice = item["voice"]
        probs = np.asarray(result.speaker_probabilities)
        save_bin(f"scd_voice{index}_probabilities.f32", probs)
        scd_out.append(
            {
                "voice_index": index,
                "num_samples": int(len(voice.samples)),
                "frame_ms": r6(result.frame_ms),
                "frame_ms_exact": result.frame_ms,
                "num_frames": int(probs.shape[0]),
                "speaker_probabilities": r6list(probs),
                "speeches": [
                    {
                        "start_sample": round((s - voice.start_timestamp) * SAMPLE_RATE),
                        "end_sample": round((e - voice.start_timestamp) * SAMPLE_RATE),
                        "num_samples": n,
                        "speaker_index": k,
                        "kind": "speaker" if k >= 0 else ("unknown_silence" if k == -1 else "unknown_overlap"),
                    }
                    for s, e, n, k in speeches
                ],
            }
        )

    write_json(
        "scd.json",
        {
            "provider": "pyannote (onnx-community/pyannote-segmentation-3.0)",
            "detector": {"threshold": 0.5, "overlap_margin": 0.1, "min_change_ms": 100, "min_speech_ms": 100},
            "window_samples": 160000,
            "voices": scd_out,
        },
    )

    # ---------------------------------------------------------------- ECAPA
    flat_speeches = [(vi, si, sp) for vi, sps in enumerate(rec.scd_speeches) for si, sp in enumerate(sps)]
    assert len(flat_speeches) == len(stt_events)
    ecapa_out = []
    speaker_vectors: list[list[np.ndarray]] = []

    for (vi, si, sp), event in zip(flat_speeches, stt_events, strict=True):
        if event.speech.kind != "speaker":
            continue

        vector = event.embedding.to_numpy()
        # Re-derive the best score for documentation; index must equal the consumer's.
        best_index, best_score = -1, -1.0

        for k, vectors in enumerate(speaker_vectors):
            score = max(calc_cosine_similarity(vector, v) for v in vectors)

            if score > best_score:
                best_index, best_score = k, score

        if best_index >= 0 and best_score >= 0.45:
            speaker_vectors[best_index].append(vector)
            assigned = best_index
        else:
            speaker_vectors.append([vector])
            assigned = len(speaker_vectors) - 1

        assert assigned == event.speech.speaker_index, (assigned, event.speech.speaker_index)
        ecapa_out.append(
            {
                "voice_index": vi,
                "speech_index": si,
                "scd_speaker_index": sp[3],
                "num_samples": sp[2],
                "assigned_speaker_index": event.speech.speaker_index,
                "best_existing_score": r6(best_score) if best_index >= 0 else None,
                "embedding": r6list(vector),
                "embedding_sha256": sha256_f32(vector),
            }
        )

    write_json(
        "ecapa.json",
        {
            "provider": "ecapa-tdnn-onnx (pranjal-pravesh/ecapa_tdnn_onnx)",
            "dimension": 192,
            "normalize": "l2",
            "speaker_similarity_threshold": 0.45,
            "note": "STT consumer embeds every speech when diarization is enabled, "
            "but only kind=='speaker' speeches get a speaker index from the embeddings.",
            "num_speeches_embedded": sum(1 for e in stt_events if e.embedding is not None),
            "speeches": ecapa_out,
            "num_speakers": len(speaker_vectors),
            "event_speaker_indices": [e.speech.speaker_index for e in stt_events],
        },
    )

    # ---------------------------------------------------------------- YAMNet
    assert len(rec.yamnet_scores) == len(ambient_events) == len(rec.clap_inputs)
    yam_out = []
    window_start = 0

    for index, (event, scores) in enumerate(zip(ambient_events, rec.yamnet_scores, strict=True)):
        n = round((event.end_timestamp - event.start_timestamp) * SAMPLE_RATE)
        clip = scores.mean(axis=0)
        save_bin(f"yamnet_window{index}_frame_scores.f32", scores)
        yam_out.append(
            {
                "window_index": index,
                "start_sample": window_start,
                "num_samples": n,
                "start_timestamp": r6(event.start_timestamp),
                "end_timestamp": r6(event.end_timestamp),
                "frame_scores_shape": list(scores.shape),
                "clip_scores": r6list(clip),
                "top3": [{"label": p.label, "score": r6(p.score)} for p in event.predictions],
            }
        )
        window_start += n

    write_json(
        "yamnet.json",
        {
            "provider": "yamnet (TFLite via ai-edge-litert)",
            "model_sha256": "10c95ea3eb9a7bb4cb8bddf6feb023250381008177ac162ce169694d05c317de",
            "aggregation": "mean over frames",
            "window_seconds": 10.0,
            "top_k": 3,
            "note": "The pinned TFLite slices waveform[0:15600] internally and returns one "
            "frame [1, 521]; samples after the first 0.975 s of a window do not affect the score.",
            "windows": yam_out,
        },
    )

    # ---------------------------------------------------------------- CLAP
    clap_out = []

    for index, (event, item) in enumerate(zip(ambient_events, rec.clap_inputs, strict=True)):
        features = item["features"]
        embedding = event.embedding.to_numpy()
        info = save_bin(f"clap_window{index}_input_features.f32", features)
        save_bin(f"clap_window{index}_resampled_48k.f32", item["resampled"])

        if index == 0:
            save_bin("clap_mel_filters.f32", item["mel_filters"])

        clap_out.append(
            {
                "window_index": index,
                "num_samples_16k": yam_out[index]["num_samples"],
                "num_samples_48k": int(len(item["resampled"])),
                "resampled_48k_sha256": sha256_f32(item["resampled"]),
                "is_longer": bool(item["is_longer"].reshape(-1)[0]),
                "input_features": {
                    "shape": list(features.shape),
                    "mean": r6(features.mean(dtype=np.float64)),
                    "std": r6(features.std(dtype=np.float64)),
                    "min": r6(features.min()),
                    "max": r6(features.max()),
                    "first3_frames": r6list(features[0, 0, :3, :]),
                    "sha256_f32": info["sha256"],
                },
                "embedding": r6list(embedding),
                "embedding_sha256": sha256_f32(embedding),
            }
        )

    first = rec.clap_inputs[0]
    write_json(
        "clap.json",
        {
            "provider": "clap-onnx (Xenova/clap-htsat-unfused audio_model.onnx)",
            "model_input_names": first["input_names"],
            "preprocessor_config": first["preprocessor_config"],
            "mel_filters_shape": list(first["mel_filters"].shape),
            "mel_filters_sha256": sha256_f32(first["mel_filters"]),
            "dimension": 512,
            "normalize": "l2",
            "windows": clap_out,
        },
    )

    total = sum(p.stat().st_size for p in FIXTURES_DIR.glob("*.json"))
    print(f"fixtures total {total} bytes")
    print("speaker indices:", [e.speech.speaker_index for e in stt_events])
    print("top3:", [[(p.label, round(p.score, 3)) for p in e.predictions] for e in ambient_events])


if __name__ == "__main__":
    sys.exit(main())
