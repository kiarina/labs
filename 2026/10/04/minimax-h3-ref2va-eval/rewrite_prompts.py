"""Rewrite raw Ref2VA requests into the official six-section format with a local VLM.

H3-Context-IR (MiniMax's hosted rewriter) is not open. This script stands in for it:
it gives a kiapi chat model the official full-reference guide (`ref-en.txt`), the
reference images (and a few frames of each reference video), and the raw request,
and asks for the six-section rewrite. Output: prompts/rewritten/<case>.txt
"""

from __future__ import annotations

import base64
import json
import os
import sys
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
KIAPI = os.environ.get("KIAPI_URL", "http://localhost:8500")
MODEL = os.environ.get("REWRITE_MODEL", "qwen3.8-27b")
GUIDE = HERE / "prompts" / "guide" / "ref-en.txt"


def image_part(path: Path) -> dict:
    mime = "image/png" if path.suffix == ".png" else "image/jpeg"
    data = base64.b64encode(path.read_bytes()).decode()
    return {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{data}"}}


def rewrite(case: dict) -> str:
    content: list[dict] = []
    for i, img in enumerate(case.get("images", []), 1):
        content.append({"type": "text", "text": f"<Picture {i}>:"})
        content.append(image_part(HERE / img))
    for i, frames in enumerate(case.get("video_frames", []), 1):
        content.append({"type": "text", "text": f"<Video {i}> (sampled frames, in order):"})
        content.extend(image_part(HERE / f) for f in frames)
    for i, note in enumerate(case.get("audio_notes", []), 1):
        content.append({"type": "text", "text": f"<Audio {i}>: {note}"})
    content.append(
        {
            "type": "text",
            "text": (
                f"Target video: {case['duration']} seconds, {case['aspect']}.\n"
                f"User request:\n{case['request']}\n\n"
                "Rewrite this into the full-reference six-section format. "
                "Output only the six sections, nothing else."
            ),
        }
    )
    body = {
        "model": MODEL,
        "temperature": 0.3,
        "max_completion_tokens": 3000,
        "messages": [
            {
                "role": "system",
                "content": (
                    "You write prompts for the MiniMax H3 video model in full-reference (Ref2VA) mode. "
                    "Follow this guide exactly.\n\n" + GUIDE.read_text()
                ),
            },
            {"role": "user", "content": content},
        ],
    }
    req = urllib.request.Request(
        f"{KIAPI}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=1800) as res:
        return json.load(res)["choices"][0]["message"]["content"].strip()


def main() -> None:
    cases = json.loads((HERE / "cases.json").read_text())
    out = HERE / "prompts" / "rewritten"
    out.mkdir(parents=True, exist_ok=True)
    names = sys.argv[1:] or [c["name"] for c in cases if c.get("rewrite", True)]
    for case in cases:
        if case["name"] not in names:
            continue
        text = rewrite(case)
        (out / f"{case['name']}.txt").write_text(text + "\n")
        print(f"== {case['name']}\n{text}\n")


if __name__ == "__main__":
    main()
