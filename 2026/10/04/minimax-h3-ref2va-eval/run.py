"""Run one Ref2VA case on h3.c or mlx-serve and record time, peak memory and the MP4.

    python3 run.py h3c A_image --size 512x512 --frames 22 --prompt raw
    python3 run.py mlxserve A_image --size 960x544 --frames 124 --prompt rewritten --turbo

Results: output/<run-id>/{video.mp4, run.json, log.txt}
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import subprocess
import tempfile
import threading
import time
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
H3C = HERE / "vendor" / "h3c" / "h3"
MLXSERVE_URL = os.environ.get("MLXSERVE_URL", "http://127.0.0.1:11234")
# Hugging Face snapshot of MiniMaxAI/MiniMax-H3 (needs Ref2VA/) and the mlx-serve pack.
H3_DIR = os.environ.get("H3_DIR", str(HERE / "vendor" / "model"))
MLXSERVE_MODEL = os.environ.get("MLXSERVE_MODEL", "")
TURBO_LORA = os.environ.get("TURBO_LORA", "")


def load_case(name: str) -> dict:
    for case in json.loads((HERE / "cases.json").read_text()):
        if case["name"] == name:
            return case
    raise SystemExit(f"unknown case {name}")


def prompt_for(case: dict, variant: str) -> str:
    if variant == "raw":
        return case["request"]
    path = case.get("prompt_file") or f"prompts/rewritten/{case['name']}.txt"
    return (HERE / path).read_text().strip()


def run_h3c(case: dict, prompt: str, w: int, h: int, frames: int, steps: int, out: Path) -> dict:
    cmd = [str(H3C), "-d", H3_DIR, "-p", prompt, "-o", str(out / "video.mp4"),
           "--width", str(w), "--height", str(h), "--frames", str(frames),
           "--steps", str(steps), "--layers", "50", "--reuse", "1", "--core-reuse", "1",
           "--profile"]
    for img in case.get("images", []):
        cmd += ["--ref-image", str(HERE / img)]
    for v in case.get("videos", []):
        cmd += ["--ref-video", str(HERE / v)]
    for v in case.get("silent_videos", []):
        cmd += ["--ref-silent-video", str(HERE / v)]
    for a in case.get("audios", []):
        cmd += ["--ref-audio", str(HERE / a)]
    t0 = time.time()
    proc = subprocess.run(["/usr/bin/time", "-l", *cmd], capture_output=True, text=True, cwd=H3C.parent)
    wall = time.time() - t0
    log = proc.stdout + proc.stderr
    (out / "log.txt").write_text(log)
    m = re.search(r"(\d+)\s+peak memory footprint", log)
    return {"returncode": proc.returncode, "wall_s": round(wall, 1),
            "peak_footprint_gb": round(int(m.group(1)) / 1e9, 2) if m else None}


def video_frames_b64(path: Path, w: int, h: int, frames: int) -> list[str]:
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["ffmpeg", "-loglevel", "error", "-i", str(path), "-frames:v", str(frames),
                        "-vf", f"scale={w}:{h}:force_original_aspect_ratio=decrease",
                        f"{tmp}/%04d.png"], check=True)
        return [base64.b64encode(p.read_bytes()).decode() for p in sorted(Path(tmp).glob("*.png"))]


def wav_b64(path: Path) -> str:
    if path.suffix != ".wav":
        with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
            subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(path), tmp.name], check=True)
            return base64.b64encode(Path(tmp.name).read_bytes()).decode()
    return base64.b64encode(path.read_bytes()).decode()


def soundtrack_b64(path: Path) -> str:
    with tempfile.NamedTemporaryFile(suffix=".wav") as tmp:
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(path), "-vn", tmp.name], check=True)
        return base64.b64encode(Path(tmp.name).read_bytes()).decode()


def server_pid() -> int:
    port = MLXSERVE_URL.rsplit(":", 1)[1]
    out = subprocess.run(["lsof", "-t", f"-iTCP:{port}", "-sTCP:LISTEN"], capture_output=True, text=True)
    return int(out.stdout.split()[0])


def footprint_bytes(pid: int) -> int:
    out = subprocess.run(["footprint", "-p", str(pid)], capture_output=True, text=True).stdout
    m = re.search(r"Footprint:\s+([\d.]+)\s+(KB|MB|GB)", out)
    if not m:
        return 0
    return int(float(m.group(1)) * {"KB": 1e3, "MB": 1e6, "GB": 1e9}[m.group(2)])


def run_mlxserve(case: dict, prompt: str, w: int, h: int, frames: int, steps: int,
                 turbo: bool, fast: bool, out: Path) -> dict:
    body: dict = {"model": MLXSERVE_MODEL, "prompt": prompt, "width": w, "height": h,
                  "num_frames": frames, "steps": steps, "seed": 42, "fast": fast}
    if case.get("images"):
        body["ref_images"] = [base64.b64encode((HERE / i).read_bytes()).decode() for i in case["images"]]
    ref_videos = []
    for v in case.get("videos", []):
        ref_videos.append({"frames": video_frames_b64(HERE / v, w, h, frames),
                           "audio": soundtrack_b64(HERE / v)})
    for v in case.get("silent_videos", []):
        ref_videos.append({"frames": video_frames_b64(HERE / v, w, h, frames)})
    if ref_videos:
        body["ref_videos"] = ref_videos
    if case.get("audios"):
        body["ref_audios"] = [wav_b64(HERE / a) for a in case["audios"]]
    if turbo:
        body["lora_paths"] = [TURBO_LORA]
        body["lora_scales"] = [1.0]

    pid = server_pid()
    peak = [0]
    done = threading.Event()

    def sample() -> None:
        while not done.is_set():
            peak[0] = max(peak[0], footprint_bytes(pid))
            done.wait(2)

    sampler = threading.Thread(target=sample, daemon=True)
    sampler.start()
    req = urllib.request.Request(f"{MLXSERVE_URL}/v1/video/generations", data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.time()
    try:
        with urllib.request.urlopen(req, timeout=6 * 3600) as res:
            data = json.load(res)
        status = 0
    except urllib.error.HTTPError as e:
        data = {"error": e.read().decode(errors="replace")}
        status = e.code
    wall = time.time() - t0
    done.set()
    sampler.join()
    (out / "log.txt").write_text(json.dumps({k: v for k, v in data.items() if "data" not in k}, indent=2))
    if status == 0:
        rgb = out / "frames.rgb"
        rgb.write_bytes(base64.b64decode(data["data"]))
        cmd = ["ffmpeg", "-loglevel", "error", "-y", "-f", "rawvideo", "-pix_fmt", "rgb24",
               "-s", f"{data['width']}x{data['height']}", "-r", str(data.get("fps", 24)), "-i", str(rgb)]
        if data.get("audio_data"):
            pcm = out / "audio.pcm"
            pcm.write_bytes(base64.b64decode(data["audio_data"]))
            cmd += ["-f", "s16le", "-ar", str(data["audio_sample_rate"]), "-ac", str(data["audio_channels"]),
                    "-i", str(pcm), "-c:a", "aac"]
        cmd += ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-shortest", str(out / "video.mp4")]
        subprocess.run(cmd, check=True)
        rgb.unlink()
        (out / "audio.pcm").unlink(missing_ok=True)
    return {"returncode": status, "wall_s": round(wall, 1), "peak_footprint_gb": round(peak[0] / 1e9, 2)}


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("engine", choices=["h3c", "mlxserve"])
    ap.add_argument("case")
    ap.add_argument("--size", default="512x512")
    ap.add_argument("--frames", type=int, default=22)
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--prompt", choices=["raw", "rewritten"], default="raw")
    ap.add_argument("--turbo", action="store_true")
    ap.add_argument("--fast", action="store_true", help="mlx-serve approximate speed-up (off for baselines)")
    ap.add_argument("--tag", default="")
    args = ap.parse_args()

    case = load_case(args.case)
    w, h = map(int, args.size.split("x"))
    prompt = prompt_for(case, args.prompt)
    variant = "turbo" if args.turbo else ("fast" if args.fast else "base")
    run_id = f"{args.engine}_{args.case}_{args.prompt}_{args.size}_f{args.frames}_s{args.steps}_{variant}{args.tag}"
    out = HERE / "output" / run_id
    out.mkdir(parents=True, exist_ok=True)
    (out / "prompt.txt").write_text(prompt + "\n")
    health = json.load(urllib.request.urlopen("http://localhost:8500/health", timeout=5))

    if args.engine == "h3c":
        result = run_h3c(case, prompt, w, h, args.frames, args.steps, out)
    else:
        result = run_mlxserve(case, prompt, w, h, args.frames, args.steps, args.turbo, args.fast, out)
    result.update({"run_id": run_id, "engine": args.engine, "case": args.case, "prompt": args.prompt,
                   "size": args.size, "frames": args.frames, "steps": args.steps, "variant": variant,
                   "kiapi_loaded_before": health["memory"]["loaded"],
                   "finished_at": time.strftime("%Y-%m-%dT%H:%M:%S%z")})
    (out / "run.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
