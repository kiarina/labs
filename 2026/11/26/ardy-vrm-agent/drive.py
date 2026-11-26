"""Drives the running app through its control API (CONTROL_PORT) with a short
conversation, saves four screenshots after each turn and prints the measurements.

    CONTROL_PORT=18795 mise run run      # in another terminal
    python3 drive.py 18795 results/
"""

import json
import sys
import time
import urllib.request

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18795
OUT = sys.argv[2] if len(sys.argv) > 2 else "results/"
BASE = f"http://127.0.0.1:{PORT}"

MESSAGES = [
    "こんにちは！ちょっと手を振ってみて",
    "今日はいいことがあったんだ。一緒に喜んで！",
    "ちょっと向こうまで歩いてきて",
    "疲れたでしょ、座って休んでいいよ",
    "最後にダンスを見せて",
]


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=30) as r:
        return r.read()


def post(path, text):
    req = urllib.request.Request(BASE + path, data=text.encode(), method="POST")
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


def status():
    return json.loads(get("/status"))


while status()["status"] != "ready":
    time.sleep(1)
time.sleep(3)

for i, message in enumerate(MESSAGES, 1):
    before = len(status()["records"])
    post("/chat", message)
    time.sleep(1)
    while status()["agent"]["running"]:
        time.sleep(0.5)
    # Let the new motion reach playback (about 1 s after the move).
    deadline = time.time() + 6
    while time.time() < deadline:
        records = status()["records"]
        if len(records) > before and records[-1].get("visibleMs") is not None:
            break
        time.sleep(0.25)
    # Four frames, 0.75 s apart, from the moment the motion became visible.
    for k in range(4):
        with open(f"{OUT}turn{i}-{k}.png", "wb") as f:
            f.write(get("/screenshot"))
        time.sleep(0.75)
    s = status()
    turn = s["agent"]["turns"][-1] if s["agent"]["turns"] else None
    print(json.dumps({
        "message": message,
        "turn": turn,
        "motion": s["prompt"],
        "record": s["records"][-1] if len(s["records"]) > before else None,
        "reply": [e["text"] for e in s["agent"]["entries"] if e["role"] == "spirit"][-1:],
    }, ensure_ascii=False))

s = status()
print(json.dumps({"fps": s["fps"], "stalls": s["stalls"], "stallSeconds": s["stallSeconds"]}))
