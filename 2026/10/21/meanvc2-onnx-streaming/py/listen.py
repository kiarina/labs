#!/usr/bin/env python3
"""Listening UI: PyTorch (upstream streaming) vs ONNX fp32 vs ONNX int8.

- The prepared rows are the outputs of parity.py and device_parity.py
  (build/listen/). Each row shares one gain (set from the PyTorch output's
  peak) so that nothing clips and the versions stay comparable.
- "Convert": upload or record a source (and optionally a reference voice);
  the server streams it through the three pipelines in 160 ms chunks with the
  same noise and returns the results with their processing times.

Open http://127.0.0.1:8777/ after `uv run python listen.py`.
"""
from __future__ import annotations

import argparse
import cgi
import io
import json
import re
import subprocess
import tempfile
import threading
import time
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import numpy as np
import soundfile as sf
import torch

import inputs
from onnx_stream import CHUNK, VARIANTS, OnnxStreamingVC
from parity import Noise, compare_wav, run_onnx, run_upstream, cat
from stream_vc import StreamingVC

LAB = Path(__file__).resolve().parents[1]
WEB = LAB / "py/web"
LISTEN = LAB / "build/listen"
OUT = LAB / "build/listen-web"
LOCK = threading.Lock()
STATE: dict = {}

LABELS = {
    "source": "元の声",
    "torch": "PyTorch（上流の流しながらの変換）",
    "onnx_fp32": "ONNX fp32",
    "onnx_int8": "ONNX int8",
    "torch_seed2": "PyTorch・別の乱数（差の目安）",
}


def write16(path: Path, audio: np.ndarray, gain: float) -> None:
    sf.write(path, np.clip(audio * gain, -1, 1), 16000, subtype="PCM_16")


def prepare_rows() -> list[dict]:
    OUT.mkdir(parents=True, exist_ok=True)
    parity = {}
    pj = LAB / "results/parity.json"
    if pj.exists():
        for c in json.loads(pj.read_text())["cases"]:
            parity[(c["case"], c["steps"])] = c
    rows = []
    for torch_path in sorted(LISTEN.glob("*_s?_torch.wav")):
        m = re.fullmatch(r"(.+)_s(\d)_torch", torch_path.stem)
        case, steps = m.group(1), int(m.group(2))
        ref, _ = sf.read(torch_path, dtype="float32")
        gain = min(1.0, 0.9 / max(1e-6, float(np.abs(ref).max())))
        files = {"source": LISTEN / f"{case}_source.wav", "torch": torch_path,
                 "onnx_fp32": LISTEN / f"{case}_s{steps}_onnx_fp32.wav",
                 "onnx_int8": LISTEN / f"{case}_s{steps}_onnx_int8.wav",
                 "torch_seed2": LISTEN / f"{case}_s{steps}_torch_seed2.wav"}
        for dev in sorted(LISTEN.glob(f"{case}_s{steps}_device_*.wav")):
            files[dev.stem.replace(f"{case}_s{steps}_", "")] = dev
        items = []
        stats = parity.get((case, steps), {})
        for key, path in files.items():
            if not path.exists():
                continue
            audio, _ = sf.read(path, dtype="float32")
            out = OUT / f"{case}_s{steps}_{key}.wav"
            write16(out, audio, 1.0 if key == "source" else gain)
            metric = None
            if key in ("onnx_fp32", "onnx_int8"):
                metric = stats.get(key.replace("onnx_", ""), {}).get("wav")
            elif key == "torch_seed2":
                metric = stats.get("upstreamOtherNoise", {}).get("wav")
            elif key.startswith("device_"):
                metric = compare_wav(audio, ref)
            items.append({"key": key, "label": LABELS.get(key, key.replace("device_", "端末: ")),
                          "url": f"/audio/{out.name}", "seconds": round(len(audio) / 16000, 2),
                          "snrDb": None if metric is None else round(metric["snrDb"], 1),
                          "lsdDb": None if metric is None else round(metric.get("lsdDb", 0), 2)})
        rows.append({"case": case, "steps": steps, "gain": round(gain, 3), "items": items,
                     "description": stats.get("description", case)})
    return rows


def to16k(data: bytes) -> np.ndarray:
    with tempfile.TemporaryDirectory() as d:
        src = Path(d) / "in"
        src.write_bytes(data)
        dst = Path(d) / "out.wav"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(src), "-ac", "1", "-ar", "16000", str(dst)],
                       check=True)
        audio, _ = sf.read(dst, dtype="float32")
    return audio


def convert(source: np.ndarray, reference: np.ndarray | None, steps: int) -> dict:
    up, ox = STATE["torch"], STATE["onnx"]
    t0 = time.perf_counter()
    if reference is not None:
        up.set_target(reference)
        ref_desc = f"アップロード・録音した参照（{len(reference) / 16000:.1f} 秒）"
    else:
        up.set_target(inputs.target_audio())
        ref_desc = inputs.TARGET_DESCRIPTION
    spk = up.runner.vc_spk_emb.numpy()
    emb_s = time.perf_counter() - t0
    for vc in ox.values():
        vc.set_target(spk)
    seed = int(time.time()) % 100000
    stamp = time.strftime("%H%M%S")
    results = []
    up.runner.ode_steps = steps
    t0 = time.perf_counter()
    ref = cat(run_upstream(up, source, seed), "wav")
    times = {"torch": time.perf_counter() - t0}
    outs = {"torch": ref}
    for name, vc in ox.items():
        vc.steps = steps
        t0 = time.perf_counter()
        outs[f"onnx_{name}"] = cat(run_onnx(vc, source, seed), "wav")
        times[f"onnx_{name}"] = time.perf_counter() - t0
    gain = min(1.0, 0.9 / max(1e-6, float(np.abs(ref).max())))
    src_path = OUT / f"live_{stamp}_source.wav"
    write16(src_path, source, 1.0)
    results.append({"key": "source", "label": LABELS["source"], "url": f"/audio/{src_path.name}",
                    "seconds": round(len(source) / 16000, 2)})
    for key, audio in outs.items():
        path = OUT / f"live_{stamp}_{key}.wav"
        write16(path, audio, gain)
        m = None if key == "torch" else compare_wav(audio, ref)
        results.append({"key": key, "label": LABELS[key], "url": f"/audio/{path.name}",
                        "seconds": round(len(audio) / 16000, 2), "convertSeconds": round(times[key], 2),
                        "snrDb": None if m is None else round(m["snrDb"], 1),
                        "lsdDb": None if m is None else round(m["lsdDb"], 2)})
    return {"case": f"live {stamp}", "steps": steps, "gain": round(gain, 3), "items": results,
            "description": f"参照: {ref_desc}・話者埋め込み {emb_s:.2f} 秒・乱数 {seed}"}


class Handler(SimpleHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json; charset=utf-8")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/":
            self.path = "/index.html"
        if self.path == "/api/rows":
            return self._json(STATE["rows"])
        if self.path.startswith("/audio/"):
            path = OUT / Path(self.path).name
            if not path.exists():
                return self.send_error(404)
            data = path.read_bytes()
            self.send_response(200)
            self.send_header("content-type", "audio/wav")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        return super().do_GET()

    def do_POST(self):
        if self.path != "/api/convert":
            return self.send_error(404)
        form = cgi.FieldStorage(fp=self.rfile, headers=self.headers, environ={"REQUEST_METHOD": "POST"})
        try:
            source = to16k(form["source"].file.read())
            reference = to16k(form["reference"].file.read()) if "reference" in form and form["reference"].filename else None
            steps = int(form.getfirst("steps", "3"))
            with LOCK, torch.inference_mode():
                row = convert(source, reference, steps)
            return self._json(row)
        except Exception as e:  # noqa: BLE001
            return self._json({"error": str(e)}, 500)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8777)
    a = p.parse_args()
    STATE["rows"] = prepare_rows()
    STATE["torch"] = StreamingVC(threads=4, model="120ms", steps=3)
    STATE["onnx"] = {v: OnnxStreamingVC(LAB / "build/onnx", suffix=VARIANTS[v], threads=4) for v in ("fp32", "int8")}
    print(f"http://127.0.0.1:{a.port}/", flush=True)
    ThreadingHTTPServer(("127.0.0.1", a.port), lambda *x: Handler(*x, directory=str(WEB))).serve_forever()


if __name__ == "__main__":
    main()
