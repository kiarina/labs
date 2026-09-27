#!/usr/bin/env python3
"""Render results/*.json into the tables quoted by the README."""

import json
import subprocess
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
res = root / "results"


def load(name):
    p = res / f"{name}.json"
    return json.loads(p.read_text()) if p.exists() else {"status": "missing"}


def crash_site(name):
    log = res / f"{name}.log"
    if not log.exists():
        return ""
    lines = log.read_text().splitlines()
    for marker in ("SetPreviewMesh", "BeginTransaction", "Assertion failed"):
        for line in lines:
            if marker in line:
                return line.split("!")[-1].split("[")[0].strip() if "!" in line else line.strip()[-90:]
    return ""


out = []
out.append("## Runtime load (Seed-san)\n")
out.append("| run | fixes | status | where it stopped |")
out.append("|---|---|---|---|")
for name, fixes in [("upstream-game-load", "00"), ("upstream-pie-load", "00"),
                    ("fix02-game-load", "00+02"), ("fix01+02-game-load", "00+01+02")]:
    d = load(name)
    site = crash_site(name) if d.get("status") != "ok" else f"loaded in {d.get('load_seconds', 0):.2f} s"
    out.append(f"| {name} | {fixes} | {d.get('status')} | {site} |")

out.append("\n## Editor import (ImportVRMFileWithOptions)\n")
out.append("| run | status | post-process ABP | morph targets |")
out.append("|---|---|---|---|")
for name in ("upstream-import", "fix01+02-import"):
    d = load(name)
    out.append(f"| {name} | {d.get('status')} | {d.get('post_process_anim_blueprint')} | {d.get('morph_targets')} |")

out.append("\n## PIE load time vs. components in the world\n")
out.append("| fixes | filler components | load_seconds (trial 1, 2) |")
out.append("|---|---|---|")
for variant, fixes in (("fix02", "00+02"), ("fix02+03", "00+02+03")):
    for f in (0, 2000):
        secs = [load(f"{variant}-pie-load-filler{f}-{t}").get("load_seconds") for t in (1, 2)]
        out.append(f"| {fixes} | {f} | " + ", ".join(f"{s:.3f}" if isinstance(s, float) else str(s) for s in secs) + " |")

out.append("\n## PIE screenshots (AA off)\n")
for a, b in (("fix02-pie-shot-1", "fix02-pie-shot-2"), ("fix02+03-pie-shot-1", "fix02+03-pie-shot-2"),
             ("fix02-pie-shot-1", "fix02+03-pie-shot-1")):
    r = subprocess.run([sys.executable, str(root / "scripts/compare_images.py"),
                        str(res / f"{a}.png"), str(res / f"{b}.png")], capture_output=True, text=True)
    out.append("- " + (r.stdout.strip() or r.stderr.strip().splitlines()[-1]).replace(str(res) + "/", ""))

out.append("\n## Spring response (PIE, gravity/wind/colliders off, 150 cm/s along +X)\n")
out.append("| model | spring | joints | tail offset X during cruise: 00+02 | 00+02+04 |")
out.append("|---|---|---|---|---|")
for model in ("Seed-san", "Seed-san-thinned"):
    base = {s["spring"]: s for s in load(f"fix02-pie-spring-{model}").get("springs", [])}
    fix = {s["spring"]: s for s in load(f"fix02+04-pie-spring-{model}").get("springs", [])}
    for name in base:
        if name.startswith(("hair_tail", "robo_wire", "hair_A")):
            out.append(f"| {model} | {name} | {base[name]['joints']} | {base[name]['cruise_tail_offset_x_cm']:.2f} cm "
                       f"| {fix.get(name, {}).get('cruise_tail_offset_x_cm', float('nan')):.2f} cm |")
out.append("")
out.append("Rest pose with the character still (same run): max joint rotation from the authored rest pose")
for model in ("Seed-san", "Seed-san-thinned"):
    out.append(f"- {model}: 00+02 {load(f'fix02-pie-spring-{model}').get('rest_max_angle_deg', 'n/a'):.2f} deg, "
               f"00+02+04 {load(f'fix02+04-pie-spring-{model}').get('rest_max_angle_deg', 'n/a'):.2f} deg")
print("\n".join(out))
