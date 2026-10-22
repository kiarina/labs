"""Transcribe every call output with Whisper, summarize the call runs, and write the listening page (output/index.html).

Run on the Mac after copying the Windows results (output/call-windows.json, output/interrupt-windows.json, output/windows-*/).

Usage: uv run evaluate.py
"""

from __future__ import annotations

import html
import json
import re
import statistics
import unicodedata

import mlx_whisper
from huggingface_hub import snapshot_download

from download import WHISPER
from engines.common import LAB_DIR

OUTPUT = LAB_DIR / "output"
TEXTS = {
    "ja": "うん、今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？",
    "en": "Tokyo is a busy city with quiet gardens and many small cafes. We can take a short walk and have some tea later.",
}


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
    runs = []
    for system in ("darwin", "windows"):
        path = OUTPUT / f"call-{system}.json"
        if not path.exists():
            continue
        data = json.loads(path.read_text(encoding="utf-8"))
        for row in data["rows"]:
            row["system"] = system
            if "cer" not in row:
                result = mlx_whisper.transcribe(str(OUTPUT / row["wav"]), path_or_hf_repo=model, language=row["case"])
                row["transcript"] = result["text"].strip()
                row["cer"] = round(cer(TEXTS[row["case"]], row["transcript"]), 3)
            runs.append(row)
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")

    groups: dict = {}
    for r in runs:
        groups.setdefault((r["system"], r["mode"], r["case"], r["schedule"]), []).append(r)
    lines = [
        "| machine | mode | case | schedule | n | first PCM (median) | starvation, no hold (median / max) | starvation, 1 s hold (max) | start with 1 s hold (median) | CER (mean) |",
        "|---|---|---|---|---:|---:|---:|---:|---:|---:|",
    ]
    for (system, mode, case, schedule), rows in sorted(groups.items()):
        med = lambda xs: statistics.median(xs)  # noqa: E731
        lines.append(
            f"| {'Mac Metal' if system == 'darwin' else 'Windows CUDA'} | {mode} | {case} | {schedule} | {len(rows)} | "
            f"{med([r['first_pcm_s'] for r in rows]):.2f} s | "
            f"{med([r['hold_0']['starvation_s'] for r in rows]):.2f} / {max(r['hold_0']['starvation_s'] for r in rows):.2f} s | "
            f"{max(r['hold_1']['starvation_s'] for r in rows):.2f} s | {med([r['hold_1']['start_s'] for r in rows]):.2f} s | "
            f"{statistics.mean([r['cer'] for r in rows]):.3f} |"
        )
    (OUTPUT / "summary.md").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))

    cells = []
    for r in sorted(runs, key=lambda r: (r["case"], r["schedule"], r["system"], r["mode"], r["seed"])):
        if r["seed"] != 42:
            continue
        cells.append(
            f"<tr><td>{r['case']}</td><td>{r['schedule']}</td><td>{'Mac' if r['system'] == 'darwin' else 'Windows'} {r['mode']}</td>"
            f"<td><audio controls preload=none src='{html.escape(r['wav'])}'></audio></td>"
            f"<td>{html.escape(' | '.join(r['spans']))}</td><td>{r['first_pcm_s']} 秒 / 途切れ {r['hold_0']['starvation_s']} 秒</td>"
            f"<td>{html.escape(r['transcript'])}</td></tr>"
        )
    page = f"""<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Call spans on qwentts.cpp</title>
<style>:root{{--bg:#fff;--fg:#1d1d1f;--mu:#6e6e73;--li:#d2d2d7}}@media (prefers-color-scheme:dark){{:root{{--bg:#1d1d1f;--fg:#f5f5f7;--mu:#a1a1a6;--li:#424245}}}}
body{{background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,sans-serif;margin:16px}}table{{border-collapse:collapse}}td,th{{border:1px solid var(--li);padding:6px;vertical-align:top}}
audio{{width:220px}}.w{{overflow-x:auto}}</style></head><body>
<h1>通話の短区間を qwentts.cpp で（1.7B BF16、ICL）</h1>
<p>区間ごとに 1 要求で作り、つないだ音（seed 42）。区間のつなぎ目の抑揚を聞いてください。参照の声: <audio controls src="reference-speaker1.wav"></audio></p>
<div class=w><table><tr><th>文</th><th>届き方</th><th>機械・流し方</th><th>音</th><th>区間</th><th>最初の音 / 途切れ（待ちなし）</th><th>Whisper</th></tr>{''.join(cells)}</table></div>
</body></html>"""
    (OUTPUT / "index.html").write_text(page)


if __name__ == "__main__":
    main()
