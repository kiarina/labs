"""Build output/<label>.html: the reference voice and every configuration run with REFERENCE_LABEL=<label>, side by side.

Usage: uv run listen_reference.py kanashimi
"""

from __future__ import annotations

import html
import json
import sys

from engines.common import LAB_DIR, TEXTS

OUTPUT = LAB_DIR / "output"


def main() -> None:
    label = sys.argv[1]
    dirs = sorted(p.parent for p in OUTPUT.glob(f"*-{label}/report.json")) + sorted(
        p.parent for p in OUTPUT.glob(f"windows/*-{label}/report.json")
    )
    order = {"mlx": 0, "qwentts": 1, "pl": 2}
    dirs.sort(key=lambda d: (order.get(d.name.split("-")[0], 9), "windows" in str(d), d.name))
    reports = [(d, json.loads((d / "report.json").read_text())) for d in dirs]
    head = "".join(
        f"<th>{html.escape(('Windows ' if 'windows' in str(d) else 'Mac ') + d.name.removesuffix('-' + label))}</th>" for d, _ in reports
    )
    rows = []
    for i, text in enumerate(TEXTS):
        cells = []
        for d, report in reports:
            run = next(r for r in report["runs"] if r["text"] == i)
            rel = d.relative_to(OUTPUT).as_posix()
            cells.append(
                f'<td><audio controls preload="none" src="{rel}/t{i}-s0.wav"></audio>'
                f'<div class=m>RTF {run["rtf"]} · 最初の音 {run["first_audio_seconds"]} 秒</div></td>'
            )
        rows.append(f"<tr><th class=t>{i}. {html.escape(text)}</th>{''.join(cells)}</tr>")
    transcript = (OUTPUT / f"reference-{label}.txt").read_text(encoding="utf-8")
    page = f"""<!doctype html><html lang="ja"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Reference {html.escape(label)}</title>
<style>:root{{--bg:#fff;--fg:#1d1d1f;--mu:#6e6e73;--li:#d2d2d7}}@media (prefers-color-scheme:dark){{:root{{--bg:#1d1d1f;--fg:#f5f5f7;--mu:#a1a1a6;--li:#424245}}}}
body{{background:var(--bg);color:var(--fg);font:14px/1.6 -apple-system,sans-serif;margin:16px}}table{{border-collapse:collapse}}td,th{{border:1px solid var(--li);padding:6px;vertical-align:top}}
th{{font-weight:normal}}th.t{{text-align:left;max-width:240px}}audio{{width:210px}}.m{{color:var(--mu);font-size:12px}}.w{{overflow-x:auto}}</style></head><body>
<h1>参照: {html.escape(label)}</h1>
<p>参照の声: <audio controls src="reference-{html.escape(label)}.wav"></audio><br><span class=m>文字起こし（ICL に渡した。pltobing は使わない）: {html.escape(transcript)}</span></p>
<p class=m>MLX = kiapi と同じ 1.7B bf16（ICL）。qwentts = ggml の 1.7B（Q8_0・BF16、ICL）。pl = pltobing 0.6B ONNX（x-vector のみ）。seed 0。</p>
<div class=w><table><tr><th>文</th>{head}</tr>{''.join(rows)}</table></div></body></html>"""
    (OUTPUT / f"{label}.html").write_text(page)
    print(OUTPUT / f"{label}.html")


if __name__ == "__main__":
    main()
