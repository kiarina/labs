# MiniMax H3 Ref2VA (reference-to-video) on a 128 GB M4 Max

[MiniMax H3](https://huggingface.co/MiniMaxAI/MiniMax-H3) (Hailuo 3.0) is a
33B joint video + stereo audio diffusion transformer. Its **Ref2VA** checkpoint
generates a clip from text plus up to 9 reference images, 3 reference videos and
3 reference audio clips (12 files at most), addressed in the prompt as
`<Picture N>`, `<Video N>` and `<Audio N>`.

This lab asks: **on a Mac Studio M4 Max 128 GB, which Ref2VA patterns work, how
long do they take, and how much memory do they need?** It is a feasibility check
for adding H3 as a video backend to a local inference server.

## Engines

| Engine | Version | Notes |
|---|---|---|
| [mlx-serve](https://github.com/ddalcu/mlx-serve) (Zig, MIT) | release v26.10.1 | HTTP server. Runs the 8-bit pack [`ddalcu/MiniMax-H3-REF2VA-MLX-Serve-8bit`](https://huggingface.co/ddalcu/MiniMax-H3-REF2VA-MLX-Serve-8bit). Supports every Ref2VA input and runtime LoRAs. Its default approximate speed-up (`fast`) was **off** for every run. |
| [h3.c](https://github.com/antirez/h3.c) (C + Metal, MIT) | `8974cc0` | CLI on the original BF16 checkpoint. Used only for the first smoke test. |

Turbo runs use the community [LightX2V Ref2VA Turbo 8-step v1.0 768p](https://huggingface.co/lightx2v/Minimax-h3-Turbo)
LoRA (Apache-2.0), ComfyUI layout (`*_comfyui_bf16.safetensors`).

Not available to any local engine: MiniMax's hosted prompt rewriter
(H3-Context-IR), the 2K regeneration stage, and the sparse-attention kernel
(the released weights run with full attention only).

## Method

- `cases.json` lists the cases. Raw requests are short English sentences that
  name the references. `rewrite_prompts.py` stands in for H3-Context-IR: it gives
  a local VLM (Qwen3.8-27B 4-bit through an OpenAI-compatible endpoint) the
  official full-reference guide (`ref-en.txt` from the MiniMax-H3 repository),
  the reference images, three frames of each reference video, and a description
  of each reference audio clip, and asks for the official six-section prompt.
  The rewrites are in `prompts/rewritten/`.
- `run.py` runs one case and records wall time, peak memory and the MP4 in
  `output/<run-id>/`. Peak memory is `/usr/bin/time -l`'s peak footprint for
  h3.c, and the maximum of `footprint -p <server pid>` sampled every 2 s for
  mlx-serve. Reference videos are cut to the generation length before sending
  (mlx-serve does the same server-side).
- Seed 42, 24 fps. Stage 1: 512×512, 22 frames (0.9 s). Stage 2: 960×544,
  124 frames (5.2 s).
- `O_official` is MiniMax's reproducible 768p Ref2VA case (a video edit with a
  reference video + its soundtrack + a voice reference) with the official,
  already rewritten prompt. Its official output is the quality reference.

The character art, voices and generated videos are not in this repository:
the private character images are the author's own, the voices were made with
macOS `say`, and the hallway and soccer clips come from the shared test assets.

## Results

All stage-2 runs are mlx-serve + Turbo LoRA, 8 steps, rewritten prompt unless noted.

| Case | References | Wall | Peak | s/step |
|---|---|---:|---:|---:|
| A (raw prompt) | 1 image | 18.2 min | 35 GB | 125 |
| A | 1 image | 18.6 min | 37 GB | 128 |
| B | 1 image + 1 voice (4.7 s) | 19.1 min | 36 GB | — |
| D | 3 images | 20.5 min | 36 GB | — |
| E | 2 images + 2 voices | 21.1 min | 36 GB | — |
| G | 1 video (3 s), continuation | 30.9 min | 38 GB | 202 |
| C | 1 image + 1 video (5.2 s) | 50.1 min | 43 GB | 339 |
| F | 1 image + 2 videos (3 s each) | 53.3 min ¹ | 43 GB | 321 |
| O_official | 1 video (5.2 s) + its soundtrack + 1 voice | 57.2 min | 41 GB | 390 |

¹ Steps 5–8 overlapped with unrelated image generation on the same GPU (321 → 390 s/step).

Stage 1 (512×512, 22 frames, raw prompt, case A):

| Engine | Steps | Wall | Peak |
|---|---:|---:|---:|
| mlx-serve | 20 | 170 s | 23 GB |
| mlx-serve + Turbo | 8 | 83 s | 25 GB |
| h3.c (BF16) | 20 | 183 s | 40 GB |

### Observations

- **Cost follows the packed sequence length.** Reference images are resized to
  the generation's pixel budget and add little: 1 → 3 images moved 18.6 →
  20.5 min. Reference video frames ride through every step: a 5.2 s video
  multiplied the step time by 2.7 (125 → 339 s), close to the quadratic attention
  cost of the longer sequence. Voice references are cheap.
- **Image references hold identity well.** In every case the character kept its
  ears, eyes, bow tie and proportions, including back views and turning around
  (C, G) and two characters of different styles in one shot (D, E). Colors can
  drift slightly toward muted pink.
- **Video references transfer setting and camera.** C reproduced the hallway,
  door and framing; F took the setting from one video and a kicking action from
  the other.
- **Strict preservation of a source video is weak.** `O_official` kept the
  scene, subject and camera push-in but shifted the framing and changed the face:
  SSIM 0.68 against the official output, while the official output is 0.93
  against its own source video. Continuation (G) did not start from the source's
  last frame (the door was closed again). Resolution (960×544 vs 1344×768), Turbo
  and 8-bit weights are all candidates; this lab did not separate them.
- **Dialogue is spoken as written.** Qwen3-Omni transcribed B as
  「こんにちは、みー猫だよ。今日も一緒にいっぱい遊ぼうね。」 and E as
  「みー猫、どこに行く？公園で遊ぼう。」, matching the prompts. Whether the two
  voices in E follow their two references is not established: Omni heard one
  speaker in E, but it also described both macOS reference voices the same way
  ("young female, high"), so it cannot tell them apart.
- **Multi-shot prompts:** the rewritten two-shot plan was ignored for A but
  followed for E (a cut at about 3 s from one speaker to the other).
- **mlx-serve holds about 29 GB while idle** after loading the pack.

## Pitfalls

- h3.c checks that the whole `FL2VA/` tree exists even for Ref2VA. Instead of
  downloading it (144 GB), `vendor/model/FL2VA` was symlinked to `Ref2VA`
  (identical layout). h3.c also reads `h3_shaders.metal` from the working
  directory.
- The diffusers-layout Turbo LoRA matches **none** of mlx-serve's module names
  (0/259); the ComfyUI layout attaches to all 208 modules it carries. mlx-serve
  reads the per-module `.alpha` (8/128 = 0.0625), so `lora_scales` stays 1.0;
  its log line "file declares no alpha" only refers to file-level metadata.
- mlx-serve keeps generating after the client disconnects and does not release
  the port until that job ends.

## Reproduce

```sh
./setup.sh                      # engines + weights (~215 GB)
python3 rewrite_prompts.py      # needs an OpenAI-compatible VLM at $KIAPI_URL
./vendor/mlx-serve/mlx-serve-macos-arm64/mlx-serve --model <pack snapshot> --serve --host 127.0.0.1 &
MLXSERVE_MODEL=<snapshot id> TURBO_LORA=<path to the comfyui LoRA> \
  python3 run.py mlxserve A_image --size 960x544 --frames 124 --steps 8 --prompt rewritten --turbo
```

`run_stage2*.sh` are the queues that produced the table. Inputs under `inputs/`
must be supplied locally (see `cases.json`).
