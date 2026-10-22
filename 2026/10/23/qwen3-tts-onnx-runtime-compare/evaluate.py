"""Transcribe every output with Whisper, compute the character error rate, and write the summary and the listening page.

Run after the benches (Whisper on the GPU would disturb their timings). Writes output/summary.json, output/summary.md and
output/index.html (open with `mise run listen`).

Usage: uv run evaluate.py
"""

from __future__ import annotations

import html
import json
import re
import unicodedata

import mlx_whisper
import numpy as np
from huggingface_hub import snapshot_download

from download import WHISPER
from engines.common import LAB_DIR, REFERENCE_TEXT, TEXTS

OUTPUT = LAB_DIR / "output"
# Order of the columns on the page and rows in the summary.
ORDER = [
    "mlx-1.7b-bf16",
    "oc-1.7b-fp32-published",
    "oc-1.7b-fp32-matched",
    "oc-1.7b-fp16-matched",
    "oc-1.7b-int4-matched",
    "oc-1.7b-fp32-matched-coreml",
    "pl-0.6b-fp32-published-t8",
    # Run on Windows (CUDA) and copied into output/windows/ (README, "Windows").
    "windows/pl-0.6b-fp32-published-cuda",
    "windows/oc-1.7b-fp16-published-cuda",
    "windows/oc-1.7b-fp16-matched-cuda",
    "windows/oc-1.7b-int4-matched-cuda",
]


def normalize(text: str) -> str:
    text = unicodedata.normalize("NFKC", text).lower()
    return re.sub(r"[\s、。，．,.!?！？「」『』（）()・…ー~〜\-]", "", text)


def cer(reference: str, hypothesis: str) -> float:
    a, b = normalize(reference), normalize(hypothesis)
    row = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        prev, row[0] = row[0], i
        for j, cb in enumerate(b, 1):
            prev, row[j] = row[j], min(row[j] + 1, row[j - 1] + 1, prev + (ca != cb))
    return row[-1] / max(len(a), 1)


def main() -> None:
    model = snapshot_download(WHISPER[0], revision=WHISPER[1])
    reports = {}
    for name in ORDER:
        path = OUTPUT / name / "report.json"
        if path.exists():
            report = json.loads(path.read_text())
            prefix = name.rsplit("/", 1)[0] + "/" if "/" in name else ""
            for run in report["runs"]:
                if not run["wav"].startswith(prefix):
                    run["wav"] = prefix + run["wav"].replace("\\", "/")
            reports[name] = report
    for report in reports.values():
        for run in report["runs"]:
            result = mlx_whisper.transcribe(str(OUTPUT / run["wav"]), path_or_hf_repo=model, language="ja")
            run["transcript"] = result["text"].strip()
            run["cer"] = round(cer(TEXTS[run["text"]], run["transcript"]), 3)
    for name, report in reports.items():
        (OUTPUT / name / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))

    summary = []
    for name, report in reports.items():
        runs = report["runs"]
        summary.append(
            {
                "engine": name,
                "machine": report["machine"],
                "description": report["description"],
                "rtf_median": round(float(np.median([r["rtf"] for r in runs])), 2),
                "first_audio_median_s": round(float(np.median([r["first_audio_seconds"] for r in runs])), 2),
                "stall_total_s": round(float(sum(r["stall_seconds"] for r in runs)), 1),
                "audio_total_s": round(float(sum(r["audio_seconds"] for r in runs)), 1),
                "generate_total_s": round(float(sum(r["generate_seconds"] for r in runs)), 1),
                "cer_mean": round(float(np.mean([r["cer"] for r in runs])), 3),
                "load_s": report["load_seconds"],
                "footprint_after_runs_gb": report["footprint_gb"]["after_runs"],
            }
        )
    (OUTPUT / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    lines = [
        "| engine | RTF (median) | first audio (median) | stalls (sum) | CER (mean) | load | footprint |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for s in summary:
        lines.append(
            f"| {s['engine']} | {s['rtf_median']} | {s['first_audio_median_s']} s | {s['stall_total_s']} s | "
            f"{s['cer_mean']} | {s['load_s']} s | {s['footprint_after_runs_gb']} GB |"
        )
    (OUTPUT / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    write_page(reports, summary)


def write_page(reports: dict, summary: list) -> None:
    head = "".join(f"<th>{html.escape(name)}</th>" for name in reports)
    rows = []
    for index, text in enumerate(TEXTS):
        cells = []
        for report in reports.values():
            run = next((r for r in report["runs"] if r["text"] == index), None)
            if run is None:
                cells.append("<td></td>")
                continue
            cells.append(
                f'<td><audio controls preload="none" src="{html.escape(run["wav"])}"></audio>'
                f'<div class="meta">RTF {run["rtf"]} · 最初の音 {run["first_audio_seconds"]} 秒 · CER {run["cer"]}</div>'
                f'<div class="asr">{html.escape(run["transcript"])}</div></td>'
            )
        rows.append(f"<tr><th class=text>{index}. {html.escape(text)}</th>{''.join(cells)}</tr>")
    stats = "".join(
        f"<tr><td>{html.escape(s['engine'])}</td><td>{html.escape(s['description'])}</td><td>{s['rtf_median']}</td>"
        f"<td>{s['first_audio_median_s']} 秒</td><td>{s['cer_mean']}</td><td>{s['footprint_after_runs_gb']} GB</td></tr>"
        for s in summary
    )
    page = f"""<!doctype html>
<html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Qwen3-TTS ONNX vs MLX</title>
<style>
:root {{ --bg: #fff; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg: #1d1d1f; --fg: #f5f5f7; --muted: #a1a1a6; --line: #424245; }} }}
body {{ background: var(--bg); color: var(--fg); font: 14px/1.5 -apple-system, sans-serif; margin: 16px; }}
table {{ border-collapse: collapse; }} td, th {{ border: 1px solid var(--line); padding: 6px; vertical-align: top; }}
th.text {{ max-width: 240px; text-align: left; font-weight: normal; }} audio {{ width: 220px; }}
.meta, .asr {{ color: var(--muted); font-size: 12px; max-width: 220px; }} .wrap {{ overflow-x: auto; }}
</style></head><body>
<h1>Qwen3-TTS: ONNX Runtime ports vs MLX bf16</h1>
<p>同じ参照の声（下）・同じ文・seed 0。列ごとに聞き比べてください。CER は Whisper large-v3-turbo の文字起こしとの文字誤り率（補助）。</p>
<p>参照の声: <audio controls src="reference-speaker1.wav"></audio> {html.escape(REFERENCE_TEXT)}</p>
<div class="wrap"><table><tr><th>engine</th><th>条件</th><th>RTF</th><th>最初の音</th><th>CER</th><th>メモリ</th></tr>{stats}</table></div>
<h2>文ごと</h2>
<div class="wrap"><table><tr><th>文</th>{head}</tr>{''.join(rows)}</table></div>
</body></html>
"""
    (OUTPUT / "index.html").write_text(page)


if __name__ == "__main__":
    main()
