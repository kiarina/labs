"""Phase 1: response shape, latency, repeatability, and input limits (English)."""

import json
import statistics
from pathlib import Path

from client import Client

OUT = Path("output")
STATE = "Help! My payouts have been failing for 3 days."
DEMO = {
    "is_urgent": {
        "type": "noul",
        "instructions": "Does this convey urgency?",
        "criteria": {"true": "Explicitly time-sensitive", "false": "No urgency expressed"},
    },
    "department": {
        "type": "choice",
        "instructions": "Which team should handle this?",
        "criteria": {
            "billing": "Payments, invoicing, refunds",
            "technical": "Bugs, outages, integrations",
            "sales": "Pricing, upgrades, new accounts",
        },
    },
    "frustration": {
        "type": "score",
        "instructions": "How frustrated is the customer?",
        "criteria": ["Calm", "Frustrated", "Very angry"],
    },
}
SENTENCE = "The quarterly report describes routine maintenance of the warehouse shelving and lighting. "
NEEDLE = "IMPORTANT: The secret launch code for project Falcon is 7429. "
NEEDLE_Q = {"needle": {"type": "noul", "instructions": "Does the state mention a launch code for project Falcon?"}}


def fill(chars: int) -> str:
    return (SENTENCE * (chars // len(SENTENCE) + 1))[:chars]


def many_questions(count: int) -> dict:
    return {
        f"q{i}": {
            "type": "noul",
            "instructions": f"Is item number {i} in the list red, considering all the context provided above carefully?",
        }
        for i in range(count)
    }


def bisect(ok, lo: int, hi: int, tolerance: int) -> tuple[int, int, int]:
    """Largest passing size in [lo, hi); returns (ok_size, ok_tokens, fail_size)."""
    tokens = 0
    while hi - lo > tolerance:
        mid = (lo + hi) // 2
        result = ok(mid)
        if result.ok:
            lo, tokens = mid, result.input_tokens
        else:
            hi = mid
    return lo, tokens, hi


def latency(client: Client, questions: dict, runs: int) -> dict:
    results = [client.ask(STATE, questions) for _ in range(runs)]
    ms = [r.ms for r in results]
    answers = [json.dumps(r.body["answers"], sort_keys=True) for r in results]
    return {
        "median_ms": round(statistics.median(ms)),
        "min_ms": round(min(ms)),
        "max_ms": round(max(ms)),
        "distinct_answers": len(set(answers)),
        "runs": runs,
        "answers": [r.body["answers"] for r in results],
    }


def main() -> None:
    client = Client()
    report: dict = {"models": client.models()}

    demo = client.ask(STATE, DEMO)
    report["demo_response"] = demo.body
    print(json.dumps(demo.body, indent=1))

    report["latency"] = {
        "noul_only": latency(client, {"is_urgent": DEMO["is_urgent"]}, 10),
        "three_questions": latency(client, DEMO, 10),
    }
    for name, row in report["latency"].items():
        print(f"latency {name}: median {row['median_ms']} ms ({row['min_ms']}-{row['max_ms']}), "
              f"distinct answers {row['distinct_answers']}/{row['runs']}")

    sweep = []
    for chars in [10_000, 100_000, 200_000, 400_000, 1_000_000, 5_000_000]:
        r = client.ask(fill(chars - len(NEEDLE)) + NEEDLE, NEEDLE_Q)
        row = {"chars": chars, "status": r.status, "ms": round(r.ms)}
        row |= {"input_tokens": r.input_tokens, "noul": r.answer("needle")["noul"]} if r.ok else {"error": r.body}
        sweep.append(row)
        print("sweep", row)
    report["state_sweep"] = sweep

    ok_chars, ok_tokens, fail_chars = bisect(lambda n: client.ask(fill(n), NEEDLE_Q), 200_000, 400_000, 500)
    report["state_limit"] = {"ok_chars": ok_chars, "ok_tokens": ok_tokens, "fail_chars": fail_chars}
    print("state limit", report["state_limit"])

    near = ok_chars - 1000
    half = near // 2
    placements = {
        "no_needle": fill(near),
        "start": NEEDLE + fill(near - len(NEEDLE)),
        "middle": fill(half) + NEEDLE + fill(near - half - len(NEEDLE)),
        "end": fill(near - len(NEEDLE)) + NEEDLE,
    }
    report["needle_near_limit"] = {}
    for name, state in placements.items():
        r = client.ask(state, NEEDLE_Q)
        report["needle_near_limit"][name] = {"input_tokens": r.input_tokens, "noul": r.answer("needle")["noul"], "ms": round(r.ms)}
    print("needle near limit", report["needle_near_limit"])

    ok_count, ok_tokens, fail_count = bisect(lambda n: client.ask("x", many_questions(n)), 2000, 3000, 10)
    report["question_count_limit"] = {"ok_questions": ok_count, "ok_tokens": ok_tokens, "fail_questions": fail_count}
    print("question count limit", report["question_count_limit"])

    combos = {
        "near_limit_state+1q": (fill(near), many_questions(1)),
        "near_limit_state+500q": (fill(near), many_questions(500)),
        "half_state+1000q": (fill(half), many_questions(1000)),
        "20k_state+15k_instruction": (fill(130_000), {"q": {"type": "noul", "instructions": "Is this about warehouses? " + fill(95_000)}}),
    }
    report["combinations"] = {}
    for name, (state, qs) in combos.items():
        r = client.ask(state, qs)
        report["combinations"][name] = {"status": r.status, "ms": round(r.ms)} | (
            {"usage": r.body["usage"]} if r.ok else {"error": r.body}
        )
        print("combination", name, report["combinations"][name])

    invalid = {
        "no_questions": {"state": "x", "model": "jev-latest", "questions": {}},
        "unknown_model": {"state": "x", "model": "jev-9", "questions": NEEDLE_Q},
        "score_one_level": {"state": "x", "model": "jev-latest",
                            "questions": {"s": {"type": "score", "instructions": "?", "criteria": ["only"]}}},
    }
    report["invalid_requests"] = {}
    for name, body in invalid.items():
        r = client.raw(body)
        report["invalid_requests"][name] = {"status": r.status, "body": r.body}
        print("invalid", name, r.status, json.dumps(r.body)[:160])

    OUT.mkdir(exist_ok=True)
    (OUT / "probe_api.json").write_text(json.dumps(report, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
