"""Wait for the turn a click in the app started, then record it like drive.py.

python3 wait_turn.py <name> <timings count before the click>
"""
import json, os, sys, time, urllib.request

PORT = int(os.environ.get("CONTROL_PORT", "8813"))
HERE = os.path.dirname(os.path.abspath(__file__))
name, before = sys.argv[1], int(sys.argv[2])


def st():
    return json.load(urllib.request.urlopen(f"http://127.0.0.1:{PORT}/state"))


t0 = time.time()
while True:
    s = st()
    if not s["running"] and len(s["timings"]) > before:
        break
    if time.time() - t0 > 600:
        raise SystemExit("timed out")
    time.sleep(0.5)
time.sleep(1.5)
req = urllib.request.Request(f"http://127.0.0.1:{PORT}/snapshot?name={name}", data=b"", method="POST")
snap = json.load(urllib.request.urlopen(req))
idx = max(i for i, e in enumerate(s["entries"]) if e["role"] in ("event", "user"))
new = s["entries"][idx:]
rec = {"name": name, "entries": new, "timing": s["timings"][-1], "canvas": s["canvas"],
       "snapshot": os.path.relpath(snap["path"], HERE) if snap.get("path") else None}
json.dump(rec, open(os.path.join(HERE, "work", "logs", f"{name}.json"), "w"), ensure_ascii=False, indent=1)
for e in new:
    print(f"  [{e['role']}] {e.get('tool','')} {e['text'][:220]}".replace("\n", " "))
t = s["timings"][-1]
print("  timing:", t["started"], "->", t["ended"], "first tool", t.get("first_tool"), "tools", t["tools"])
