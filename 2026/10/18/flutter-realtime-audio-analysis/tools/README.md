# tools: Python reference fixtures and YAMNet ONNX conversion

This directory produces what the Dart port is checked against:

- `fixtures/*.json`: outputs of the real kiarina-agi-audio code (kiarina-python commit
  `9d483457`, kiarina-agi-audio 2.28.0) on one input file.
- `models/yamnet/yamnet.onnx` (gitignored): the YAMNet TFLite that kiarina uses, converted to ONNX
  so the Dart app needs only ONNX Runtime.

## Input

`work/conversation_16k.wav` (gitignored): 16 kHz mono PCM16, 226,736 samples (14.171 s), two Japanese
speakers. It is derived from the shared asset `tests/assets/mp3/conversation_2speaker_14s_16k.mp3`
(sha256 `e671750e...6e5d7e3d`):

```sh
mise run //:test-assets:download   # or: make download-test-assets (repository root)
ffmpeg -i tests/assets/mp3/conversation_2speaker_14s_16k.mp3 -ac 1 -ar 16000 -c:a pcm_s16le \
  2026/10/18/flutter-realtime-audio-analysis/work/conversation_16k.wav
```

With ffmpeg 9.0.2 the WAV has sha256 `76f9ec20...878f8859a9b`; the PCM payload sha256 is in
`fixtures/input.json` (`pcm16_sha256`). The float32 signal is `int16 / 32768`, which the script
asserts is identical to what kiarina's `FileAudioSource` reads through libsndfile.

## Reproduce

Prerequisites: `uv`, `ffmpeg`, a kiarina-python checkout next to labs
(`~/src/github.com/kiarina/{labs,kiarina-python}`) at commit `9d483457`. Run from the lab directory:

```sh
uv run --project tools python tools/make_fixtures.py        # fixtures/{input,vad,scd,ecapa,yamnet,clap}.json
tools/convert_yamnet.sh                                     # models/yamnet/yamnet.onnx
uv run --project tools python tools/validate_yamnet_onnx.py # fixtures/yamnet_onnx_parity.json
uv run --project tools python tools/describe_models.py      # fixtures/models.json
```

- `pyproject.toml` installs kiarina-agi-audio from the local checkout as an editable path dependency
  (read-only use). Because that package is a member of the kiarina-python uv workspace, uv also takes
  its kiarina-* dependencies from the same checkout (see `uv.lock`), so everything comes from one commit.
- Models are downloaded by kiarina's own code. `make_fixtures.py` sets
  `KIARINA_UTILS_APP_USER_CACHE_DIR=models/kiarina-cache` (gitignored) so the downloads stay inside the
  lab; kiarina verifies each file's sha256.
- Intermediate arrays for full diffs are written to `work/fixtures-bin/*.f32` (little-endian float32,
  gitignored; each JSON lists the sha256 of the same bytes): CLAP 48 kHz waveform and `input_features`
  for both windows, the CLAP mel filter bank (513 x 64), SCD probabilities, YAMNet frame scores.
- `make_fixtures.py` and `convert_yamnet.sh` are byte-reproducible (each was run two or three times
  and the outputs compared). `yamnet_onnx_parity.json` is too, except for the timing values.

### Versions

| Environment | Packages |
| --- | --- |
| fixtures (`.venv`, uv.lock) | CPython 3.12.10, onnxruntime 1.31.0, ai-edge-litert 2.3.0, numpy 2.5.4, soundfile 0.14.0, onnx 1.23.2 |
| conversion (`.venv-tf`, `convert-requirements.txt`) | CPython 3.11.15 (uv-managed), tensorflow 2.15.1, tf2onnx 1.16.1, onnx 1.16.2, numpy 1.26.4, protobuf 3.20.3 |

Machine: macOS (Darwin 27), Apple silicon (arm64). These versions installed cleanly on the first
attempt; newer TensorFlow was not tried.

## How the fixtures are made

`make_fixtures.py` runs the same pipeline as kiarina-agi-data-builder's audio analysis
(`build_analysis_enabled`): `FileAudioSource` (`file?sample_rate=16000&start_timestamp=0.0`) feeds
every chunk to the `stt?diarization_enabled=true` and `ambient?window_seconds=10.0&top_k=3`
consumers, then both are flushed. The only change is `asr_model=mock`, so no ASR service is called.
Values are captured with observe-only wrappers around `VoiceDetector.detect/_emit`, `SCDModel.predict`,
`SpeakerChangeDetector.detect`, `YamnetAudioTaggingProvider._invoke` and
`ClapOnnxAudioEmbeddingProvider._extract_input_features`; each wrapper calls the original unchanged.
Floats in JSON are rounded to 6 significant digits (the `.f32` files are exact).

Chunk size: kiarina's file, mic and numpy sources all default to `chunk_size=512`; the data builder
does not override it. The fixture uses 512. The file source also yields the final partial chunk
(here 432 samples), and Silero accepts it (64 + 432 = 496 samples in).

| File | Contents |
| --- | --- |
| `input.json` | input hashes and the specifiers used |
| `vad.json` | Silero probability for all 443 chunks; the `VoiceDetector` (0.5 / 500 ms / 300 ms) voices with the chunks each voice concatenates; 3 extra `VoiceDetector` settings replayed on the recorded probabilities |
| `scd.json` | per voice: pyannote `speaker_probabilities` [frames, 3], `frame_ms`, and the `SpeakerChangeDetector` speeches (samples relative to the voice) |
| `ecapa.json` | 192-d L2-normalized embedding per `speaker` speech, the cosine score against the existing speakers, and the speaker index the STT consumer assigned (threshold 0.45) |
| `yamnet.json` | per 10 s window: frame score shape, mean clip scores (521), top-3 |
| `clap.json` | per window: 48 kHz sample count, `is_longer`, `input_features` summary + first 3 frames + sha256, 512-d embedding; the merged preprocessor config |
| `yamnet_onnx_parity.json` | TFLite vs converted ONNX, timing, ONNX scores for both windows |
| `models.json` | url, pinned url, sha256, bytes, license, ONNX/TFLite input and output names, types, shapes, opsets |

### Results on this input

- VAD: 443 chunks (442 x 512 + 1 x 432); 346 have p >= 0.5. With the default settings there is
  **one** voice, emitted only by `flush()`: start 0, end 226,736 (end of input), 225,200 samples.
  The extra settings in `voice_detector_variants` give 10 to 12 voices, which exercise the
  silence-triggered emit path.
- SCD: 829 frames, `frame_ms` = 16.97792869... (10,000 / 589). 6 speeches, all `speaker`, with
  pyannote local indices 2,1,2,1,2,1.
- ECAPA: the STT consumer assigns speakers 0,1,0,1,0,1, so 2 speakers. Scores against the best
  existing speaker: 0.092 (new speaker), then 0.470, 0.586, 0.584, 0.599.
- YAMNet top-3: window 0 (160,000 samples) Speech 0.992, Speech synthesizer 0.043, Narration,
  monologue 0.016; window 1 (66,736 samples, from flush) Speech 0.941, Speech synthesizer 0.012,
  Narration, monologue 0.008.
- CLAP: 480,000 and 200,208 samples at 48 kHz, `is_longer` false for both, `input_features`
  [1, 1, 1001, 64].

### Behaviour the Dart port has to reproduce (observed in kiarina's code)

- **Voice samples are not one contiguous slice.** While the detector waits out `min_silence_ms`, it keeps
  appending silent chunks only within `voice_pad_ms` after the last voiced chunk. If speech resumes
  before `min_silence_ms`, the chunks in between are dropped. Here 3 chunks (starts 32256, 32768,
  78848) are missing, so `Voice.samples` has 225,200 samples while start..end covers 226,736.
  `vad.json` lists the chunks (`buffer_chunks`) each voice concatenates.
- The voice `end_timestamp` is `min(last voiced chunk end + pad, cursor)`, and the voice `start` is the
  first pre-buffer chunk kept within `voice_pad_ms` before the first voiced chunk.
- SCD splits a voice into 10 s chunks, zero-pads the last one, concatenates the frames and cuts them
  to `round(len / 16000 * 1000 / frame_ms)`. The model output named `logits` has 7 powerset classes
  and is treated as log-probabilities (`exp`, then the powerset-to-speaker mapping).
- With `diarization_enabled=true` the STT consumer embeds every speech, but only `speaker` speeches
  get an index from the embeddings; they are compared by maximum cosine over each speaker's stored
  embeddings, in order, and a new speaker is added when the best score is below 0.45.
- CLAP: the model has a single input `input_features`, so `is_longer` is computed but never fed.
  The preprocessor config file adds `nb_max_samples: 480000`, which sets the frame count to
  480,000 / 480 + 1 = 1001.
- Resampling (CLAP 16 -> 48 kHz) is `np.interp` on `linspace` positions, not a band-limited resampler.

## YAMNet: TFLite -> ONNX

**Outcome: the whole model converted, frontend included.** `tf2onnx --tflite --opset 17` turned
`RFFT2D` into a MatMul with a constant DFT matrix plus Pow/Sqrt for the magnitude, so no `DFT` or `STFT`
op is needed. Opset 18 also converted (it uses `ReduceMean` where 17 uses `GlobalAveragePool`); 17 is
kept for wider runtime support. After conversion the script makes the input dimension symbolic and renames nodes and
tensors in graph order, because tf2onnx's generated name suffixes change from run to run (the graph
does not; outputs were identical between runs). `PYTHONHASHSEED=0` did not fix this.

| | value |
| --- | --- |
| file | `models/yamnet/yamnet.onnx` (gitignored, not hosted yet) |
| sha256 | `8b977c9434c28c29d769e4d9e90b8e9752cdf9aaf6465eaa90a8eb535e83c46c` |
| bytes | 4,999,860 |
| input | `waveform_binary` float32 [`num_samples`] |
| output | `tower0/network/layer32/final_output` float32 [1, 521] |
| opsets | ai.onnx 17 (the graph also imports ai.onnx.ml 2) |

### What the pinned TFLite actually computes

The model kiarina pins (`lite-model/yamnet/classification/tflite/1`, sha256 `10c95ea3...`) is not the
multi-frame YAMNet:

- Its input is declared `[15600]` and its first op is `StridedSlice waveform[0:15600]`. The output is
  always **one** frame `[1, 521]`, whatever length kiarina resizes the input to. Measured: the 10 s
  window gives exactly the same scores as its first 15,600 samples, and zeroing everything after
  1 s changes nothing (max diff 0.0). **kiarina's "mean over frames" over a 10 s window is therefore the
  score of the window's first 0.975 s only.**
- Inputs shorter than 15,600 samples fail (TFLite with XNNPACK: "failed to reshape"; ONNX: Reshape
  error). kiarina's ambient consumer would raise on a flush remainder under 0.975 s.
- It is int8-quantized (int8 weights and activations; QUANTIZE after the log-mel, DEQUANTIZE at the
  end). Scores are multiples of 1/256.
- Frontend in the graph: 25 ms frames (400 samples) at a 10 ms hop (160), 96 frames, Hann window,
  zero-pad to 512, RFFT magnitude (not power), a 257 -> 64 mel matrix, + offset, log; then a [1, 96, 64]
  patch.

### Parity (ONNX Runtime 1.31.0 CPU vs TFLite with XNNPACK, as kiarina runs it)

1 LSB = 1/256 = 0.0039.

| case | samples | max abs diff | mean abs diff | top-1 equal | top-3 equal |
| --- | ---: | ---: | ---: | --- | --- |
| window 0 | 160,000 | 0.0078 (2 LSB) | 3.7e-5 | yes | yes |
| window 1 (remainder) | 66,736 | 0.0156 (4 LSB) | 1.1e-4 | yes | no (2nd: Inside, small room 0.0156 vs Speech synthesizer 0.0117) |
| 0.5 s slice | 8,000 | both fail | | | |
| 1 s slice | 16,000 | 0.0117 (3 LSB) | 5.2e-5 | yes | no (2nd and 3rd swapped) |
| 3.3 s slice | 52,800 | 0.0117 (3 LSB) | 5.2e-5 | yes | no (same first 15,600 samples as the 1 s slice) |
| exactly 15,600 | 15,600 | 0.0234 (6 LSB) | 9.0e-5 | yes | yes |

All 53 crops of 15,600 samples at a 0.25 s hop over the file:

| compared with TFLite + XNNPACK | max diff | top-1 equal | top-3 equal | bit-exact crops |
| --- | ---: | ---: | ---: | ---: |
| ONNX, ORT default optimization | 18 LSB | 53 / 53 | 39 / 53 | 2 |
| ONNX, ORT optimizations disabled | 18 LSB | 53 / 53 | 39 / 53 | 1 |
| TFLite builtin int8 kernels (no XNNPACK) | 17 LSB | 53 / 53 | 47 / 53 | 11 |

Interpretation: the ONNX differs from kiarina's TFLite by about as much as TFLite's own two int8
kernel sets differ from each other. Top-1 always agrees; top-2 and top-3 are low scores (a few LSB)
and swap often. A Dart port that runs this ONNX should compare against the ONNX scores stored in
`yamnet_onnx_parity.json` (`cases[*].ort_default.scores`) for exact parity, and against the TFLite
fixture with a tolerance of about 20 LSB and top-1 equality.

Timing, one 10 s window (only 15,600 samples are processed), same machine, median of 20:
TFLite + XNNPACK 0.94 ms invoke only (2.0 ms including the resize and `allocate_tensors` that kiarina
does whenever the length changes); ONNX Runtime 0.6 to 0.8 ms with default optimization and 2.3 to 9.6 ms
with optimizations disabled (range over three runs; other jobs were running on the machine).

## Models

From `fixtures/models.json` (ONNX shapes as reported by onnxruntime 1.31.0):

| model | bytes | license | inputs | outputs | opset |
| --- | ---: | --- | --- | --- | --- |
| silero-vad | 2,327,524 | MIT | `input` f32 [?, ?], `state` f32 [2, ?, 128], `sr` i64 [] | `output` f32 [?, 1], `stateN` f32 [?, ?, ?] | 16 |
| pyannote-segmentation-3.0 (onnx-community) | 5,986,908 | MIT | `input_values` f32 [batch, channels, samples] | `logits` f32 [batch, frames, 7] | 17 |
| ecapa-tdnn-onnx | 84,028,639 | MIT | `audio` f32 [s42, s51] | `embedding` f32 [1, 1, 192] | 18 |
| clap-htsat-unfused audio_model (Xenova) | 117,528,416 | Apache-2.0 (from laion) | `input_features` f32 [batch, channels, height, width] | `audio_embeds` f32 [batch, 512] | 11 |
| yamnet.onnx (this conversion) | 4,999,860 | Apache-2.0 (from YAMNet) | `waveform_binary` f32 [num_samples] | `tower0/network/layer32/final_output` f32 [1, 521] | 17 |

Also listed: the CLAP `preprocessor_config.json` (laion, pinned revision), the YAMNet TFLite and the
class map CSV.

Download notes:

- kiarina's URLs for Silero VAD (`master`), onnx-community pyannote (`main`) and Xenova CLAP (`main`)
  follow moving branches; only the sha256 is pinned. `models.json` adds a `pinned_url` per model:
  a commit/revision URL that served the same bytes on 2026-10-18 (Silero `bfdc019`, pyannote
  `733a93b`, Xenova `c28f288`).
- `tfhub.dev` now redirects the YAMNet TFLite to a short-lived signed Kaggle storage URL.
- The original `pyannote/segmentation-3.0` is gated on Hugging Face; the onnx-community export is not.
- The Xenova CLAP card has no license field; Apache-2.0 is the license of the base model
  `laion/clap-htsat-unfused`. The ECAPA card says MIT and does not name its source checkpoint.
- The YAMNet license (Apache-2.0) is taken from the TF Hub / Kaggle model page and the tensorflow/models
  repository; it was not re-checked through an API.

## Not verified

- Only one input file. With the default settings it gives a single voice and 6 speeches; the
  `VoiceDetector` emit-on-silence path is covered only by the replayed variants.
- Parity and timing were measured only on macOS arm64 with the CPU execution provider.
- The YAMNet ONNX has not been run in onnxruntime-web or the mobile runtimes yet.
