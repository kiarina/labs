"""Prints the parts of a replay report worth reading (without frames/events)."""

import json
import sys

r = json.load(open(sys.argv[1]))
if not r.get("ok"):
    print(r.get("error"))
    sys.exit(1)
p = r["replay"]
out = {k: p[k] for k in ("realtime", "fps", "loops", "stream_frames", "analyzed", "dropped", "wall_s", "stream_s", "lag_ms", "stage_ms", "entities", "events", "embeddings", "rss_mb", "checks") if k in p}
print(json.dumps(out, indent=1))
print("events:")
for e in p["event_list"]:
    print("  ", e["at"][11:22], e["kind"], e["entity"], e["label"], "returned" if e.get("returned") else "", e.get("similarity", ""), e.get("from", ""))
