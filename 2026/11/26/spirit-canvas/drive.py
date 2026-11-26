"""Drive the running app through its control port (CONTROL_PORT).

python3 drive.py <name> send <text>          send a user message, wait, snapshot
python3 drive.py <name> event <kind> <id> [value]   fire a canvas event, wait, snapshot
python3 drive.py <name> mode <chat|canvas>
python3 drive.py <name> state                 print the entries and timings

Each step waits until the spirit's turn ends, saves work/logs/<name>.png and
appends the new entries to work/logs/<name>.json.
"""

import json
import os
import sys
import time
import urllib.parse
import urllib.request

PORT = int(os.environ.get("CONTROL_PORT", "8813"))
BASE = f"http://127.0.0.1:{PORT}"
HERE = os.path.dirname(os.path.abspath(__file__))


def call(path, body=None):
    req = urllib.request.Request(BASE + path, data=body.encode() if body is not None else None, method="POST" if body is not None or path != "/state" else "GET")
    with urllib.request.urlopen(req, timeout=600) as r:
        return json.loads(r.read())


def wait_idle(before, timeout=600):
    t0 = time.time()
    # The turn may start a moment after the request returns.
    time.sleep(1.0)
    while time.time() - t0 < timeout:
        s = call("/state")
        if not s["running"] and len(s["timings"]) > before:
            return s, time.time() - t0
        time.sleep(0.5)
    raise SystemExit("timed out")


def main():
    name, cmd, *rest = sys.argv[1:]
    s0 = call("/state")
    n0 = len(s0["entries"])
    t0 = len(s0["timings"])
    if cmd == "send":
        call("/send", rest[0])
    elif cmd == "event":
        kind, eid, *value = rest
        q = {"kind": kind, "id": eid}
        if value:
            q["value"] = value[0]
        call("/event?" + urllib.parse.urlencode(q), "")
    elif cmd == "mode":
        call("/mode?m=" + rest[0], "")
        print("ok")
        return
    elif cmd == "state":
        print(json.dumps(s0, ensure_ascii=False, indent=1))
        return
    s, waited = wait_idle(t0)
    time.sleep(1.5)  # let animations and media settle a little
    snap = call(f"/snapshot?name={urllib.parse.quote(name)}", "")
    new = s["entries"][n0:]
    record = {
        "name": name,
        "cmd": [cmd, *rest],
        "waited_s": round(waited, 1),
        "timing": s["timings"][-1] if s["timings"] else None,
        "entries": new,
        "canvas": s["canvas"],
        "snapshot": os.path.relpath(snap["path"], HERE) if snap.get("path") else None,
    }
    path = os.path.join(HERE, "work", "logs", f"{name}.json")
    with open(path, "w") as f:
        json.dump(record, f, ensure_ascii=False, indent=1)
    for e in new:
        if e["role"] == "tool":
            print(f"  [tool] {e['tool']}: {e['text'][:160]}")
        else:
            print(f"  [{e['role']}] {e['text'][:400]}")
    print(f"  waited {waited:.1f}s, timing: {record['timing']}")


if __name__ == "__main__":
    main()
