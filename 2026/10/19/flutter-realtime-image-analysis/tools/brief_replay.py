"""One line per replay report: drops, stage medians, entities, re-identification checks."""

import json
import sys

for path in sys.argv[1:]:
    r = json.load(open(path))
    if not r.get("ok"):
        print(path, "ERROR", (r.get("error") or "")[:300])
        continue
    p = r["replay"]
    c = p["checks"]
    print(path.split("report-")[-1], {k: p.get(k) for k in ("fps", "analyzed", "dropped", "wall_s")},
          {k.replace("_ms", ""): v.get("median") for k, v in p["stage_ms"].items()},
          "p90", p["stage_ms"]["total_ms"].get("p90"), p["entities"],
          "face_back", c["face_came_back_as_same_entity"], "scene_back", c["dialogue_scene_came_back"],
          "rss", [round(x) for x in p["rss_mb"]][:4])
