"""Spirits Garden's call speech on qwentts.cpp: a transcript that arrives a few characters at a time, cut into short spans,
each span synthesized as one request, the spans played back to back as one utterance.

Reproduces the inputs of labs 2026/10/22/qwen3-tts-live-audio-decoupling (the method the prototype uses with kiapi today):
the same Japanese and English scripts, the same arrival schedules (`ordinary`: one character every 130 ms (ja) / 60 ms (en);
`recorded`: the cumulative character fractions of a real call, `schedules.json`; `pause`: `ordinary` with the producer
stopped for 2 s at two thirds; `full`: all text at once), the same span rule (`boundary`), and the same seeds.

Two ways to feed the server:
- `serial`: one request at a time, in order (the next span starts when the previous one has finished)
- `pipelined`: the next span's request starts as soon as the span is complete (`--max-batch 2`); its PCM is held until the
  previous span has finished, so playback order is kept

For every run it records each PCM arrival in playback order (seconds from the first text) and the transcript producer's
events, then computes the first PCM and the cumulative starvation if playback starts after holding 0 / 0.5 / 1 s
(gaps under 20 ms ignored, as in the earlier lab).

Usage: uv run call.py [--modes serial pipelined] [--seeds 42 43 44]
"""

from __future__ import annotations

import argparse
import json
import math
import platform
import queue
import re
import threading
import time

import numpy as np
import soundfile as sf

from engines.common import LAB_DIR, REFERENCE_LABEL, SAMPLE_RATE
from engines.server import Server

TEXTS = {
    "ja": "うん、今日はいい天気ですね。少し散歩してから、駅前のカフェでコーヒーを飲みませんか？",
    "en": "Tokyo is a busy city with quiet gardens and many small cafes. We can take a short walk and have some tea later.",
}
LANGUAGE = {"ja": "Japanese", "en": "English"}
INTERVAL = {"ja": 0.13, "en": 0.06}
HOLDS = [0.0, 0.5, 1.0]


def boundary(text: str, language: str, closed: bool) -> int:
    """The prototype's span rule (labs 2026/10/22/qwen3-tts-live-audio-decoupling, segments.py)."""
    minimum = 8 if language == "ja" else 14
    for match in re.finditer(r"[、。！？!?.,;:]\s*", text):
        if match.end() >= minimum:
            return match.end()
    if language == "en":
        spaces = list(re.finditer(r"\s+", text))
        if len(spaces) >= 6:
            return spaces[5].end()
    elif len(text) >= 24:
        return 24
    return len(text) if closed else 0


def produce(case: str, schedule: str, start: float, push, events: list) -> None:
    text = TEXTS[case]
    now = lambda: time.perf_counter() - start  # noqa: E731
    if schedule == "full":
        push(text)
    elif schedule == "recorded":
        cadence = json.loads((LAB_DIR / "schedules.json").read_text())[case]
        cursor = 0
        for item in cadence["arrivals"]:
            time.sleep(max(0.0, start + item["t"] - time.perf_counter()))
            through = min(len(text), math.ceil(len(text) * item["fraction"]))
            if through > cursor:
                push(text[cursor:through])
                cursor = through
        time.sleep(max(0.0, start + cadence["done_s"] - time.perf_counter()))
    else:
        for i, ch in enumerate(text):
            if schedule == "pause" and i == len(text) * 2 // 3:
                events.append({"type": "pause", "t": now(), "duration_s": 2.0})
                time.sleep(2.0)
            push(ch)
            time.sleep(INTERVAL[case])
    events.append({"type": "text.done", "t": now()})


def starvation(arrivals: list[tuple[float, int]], hold: float) -> tuple[float, float]:
    """(playback start, cumulative starvation) when playback starts `hold` seconds after the first PCM."""
    start = arrivals[0][0] + hold
    play_end, gaps = start, 0.0
    for at, samples in arrivals:
        if at > play_end:
            if at - play_end >= 0.02:
                gaps += at - play_end
            play_end = at
        play_end += samples / SAMPLE_RATE
    return start, gaps


def run(server: Server, case: str, schedule: str, mode: str, seed: int) -> dict:
    spans: queue.Queue = queue.Queue()
    events: list = []
    lock = threading.Lock()
    state = {"text": "", "cursor": 0, "closed": False}
    start = time.perf_counter()
    now = lambda: time.perf_counter() - start  # noqa: E731

    def cut():
        while True:
            n = boundary(state["text"][state["cursor"] :], case, state["closed"])
            if not n:
                return
            piece = state["text"][state["cursor"] : state["cursor"] + n]
            state["cursor"] += n
            events.append({"type": "span", "t": now(), "chars": n})
            spans.put(piece)

    def push(piece):
        with lock:
            state["text"] += piece
            events.append({"type": "append", "t": now(), "chars": len(state["text"])})
            cut()

    def producer():
        produce(case, schedule, start, push, events)
        with lock:
            state["closed"] = True
            cut()
        spans.put(None)

    threading.Thread(target=producer, daemon=True).start()

    # Each span's PCM goes to its own list; playback order is span order.
    results: list[dict] = []

    def synthesize(piece: str, record: dict):
        record["request_t"] = now()

        def on_pcm(pcm):
            record["arrivals"].append((now(), len(pcm)))
            record["pcm"].append(pcm)

        server.stream(piece, LANGUAGE[case], seed, on_pcm)
        record["done_t"] = now()

    threads = []
    while True:
        piece = spans.get()
        if piece is None:
            break
        record = {"text": piece, "arrivals": [], "pcm": []}
        results.append(record)
        if mode == "serial":
            synthesize(piece, record)
        else:
            if len(threads) >= 2:  # at most two requests in flight
                threads.pop(0).join()
            t = threading.Thread(target=synthesize, args=(piece, record))
            t.start()
            threads.append(t)
    for t in threads:
        t.join()

    # Playback-order arrival stream: a span's PCM cannot play before the previous span has fully arrived.
    ordered, ready = [], 0.0
    for record in results:
        for at, samples in record["arrivals"]:
            ordered.append((max(at, ready), samples))
        if ordered:
            ready = ordered[-1][0]
    audio = np.concatenate([np.concatenate(r["pcm"]) for r in results if r["pcm"]])
    label = f"-{REFERENCE_LABEL}" if REFERENCE_LABEL else ""
    out = LAB_DIR / "output" / f"{platform.system().lower()}-{mode}{label}" / f"{case}-{schedule}-s{seed}.wav"
    out.parent.mkdir(parents=True, exist_ok=True)
    sf.write(out, np.clip(audio, -1, 1), SAMPLE_RATE, subtype="PCM_16")
    text_done = next(e["t"] for e in events if e["type"] == "text.done")
    row = {
        "case": case, "schedule": schedule, "mode": mode, "seed": seed,
        "wav": str(out.relative_to(LAB_DIR / "output").as_posix()),
        "spans": [r["text"] for r in results],
        "audio_seconds": round(len(audio) / SAMPLE_RATE, 3),
        "text_done_s": round(text_done, 3),
        "first_pcm_s": round(ordered[0][0], 3),
        "last_pcm_s": round(ordered[-1][0], 3),
        "span_first_pcm_after_request_s": [round(r["arrivals"][0][0] - r["request_t"], 3) for r in results if r["arrivals"]],
    }
    for hold in HOLDS:
        begin, gaps = starvation(ordered, hold)
        row[f"hold_{hold:g}"] = {"start_s": round(begin, 3), "starvation_s": round(gaps, 3)}
    return row


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--modes", nargs="*", default=["serial", "pipelined"])
    parser.add_argument("--seeds", type=int, nargs="*", default=[42, 43, 44])
    parser.add_argument("--cases", nargs="*", default=["ja", "en"])
    parser.add_argument("--schedules", nargs="*", default=["ordinary", "recorded", "pause"])
    args = parser.parse_args()
    rows = []
    for mode in args.modes:
        server = Server(max_batch=2 if mode == "pipelined" else 1, log_name=f"server-{mode}")
        try:
            server.stream("こんにちは。", "Japanese", 0, lambda pcm: None)  # warm-up, not counted
            for seed in args.seeds:
                for case in args.cases:
                    schedules = (["full"] if seed == args.seeds[0] else []) + args.schedules
                    for schedule in schedules:
                        row = run(server, case, schedule, mode, seed)
                        rows.append(row)
                        print(json.dumps({k: row[k] for k in ("mode", "case", "schedule", "seed", "first_pcm_s", "hold_0", "hold_1")}), flush=True)
        finally:
            server.close()
    out = LAB_DIR / f"output/call-{platform.system().lower()}{'-' + REFERENCE_LABEL if REFERENCE_LABEL else ''}.json"
    out.write_text(json.dumps({"machine": platform.platform(), "rows": rows}, ensure_ascii=False, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
