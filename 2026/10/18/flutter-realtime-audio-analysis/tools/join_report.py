"""Join `HEARING_LAB_REPORT i/n ...` lines (from logcat, device consoles or
stdout) back into one JSON report."""
import json
import re
import sys

parts = {}
total = 0
for line in sys.stdin:
    m = re.search(r"HEARING_LAB_REPORT (\d+)/(\d+) (.*)$", line.rstrip("\n"))
    if m:
        parts[int(m.group(1))] = m.group(3)
        total = int(m.group(2))
missing = [i for i in range(1, total + 1) if i not in parts]
if not total or missing:
    sys.exit(f"incomplete report: {total=} {missing=}")
print(json.dumps(json.loads("".join(parts[i] for i in range(1, total + 1))), ensure_ascii=False, indent=1))
