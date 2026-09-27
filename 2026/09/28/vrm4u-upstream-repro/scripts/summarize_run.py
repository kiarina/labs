#!/usr/bin/env python3
"""Reduce an Editor log to the lines that matter and classify the run."""

import json
import os
import re
import sys
from pathlib import Path

raw_log, out_log, out_json, mode, exit_code = sys.argv[1:6]
lab_root = str(Path(__file__).resolve().parents[1])
home = os.path.expanduser("~")


def scrub(line: str) -> str:
    return line.replace(lab_root, "<lab>").replace(home, "~")


lines = Path(raw_log).read_text(errors="replace").splitlines() if Path(raw_log).exists() else []
keep = []
crash_at = None
for i, line in enumerate(lines):
    if re.search(r"Assertion failed|Fatal error|Unhandled Exception|Caught signal|=== Critical error", line) and crash_at is None:
        crash_at = i
    if re.search(r"VRMREPRO|LogVrmRepro|Assertion failed|Fatal error|Ensure condition failed|Caught signal|Critical error|timeout after", line):
        keep.append(line)
if crash_at is not None:
    keep.append("---- crash context ----")
    keep.extend(lines[crash_at:crash_at + 40])
Path(out_log).write_text("\n".join(scrub(l) for l in keep) + "\n")

result = json.loads(Path(out_json).read_text()) if Path(out_json).exists() else {}
if not result:
    result = {"status": "timeout" if any("timeout after" in l for l in lines) else "crashed"}
    if crash_at is not None:
        result["crash"] = scrub(lines[crash_at].strip())
result["mode"] = mode
result["editor_exit_code"] = int(exit_code)
result["ensures"] = sum(1 for l in lines if "Ensure condition failed" in l)
Path(out_json).write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n")
print(json.dumps(result, ensure_ascii=False))
