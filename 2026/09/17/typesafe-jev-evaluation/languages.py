"""Phases 2-3: language support, token density, input limit, long-context retrieval, repeatability."""

import argparse
import json
import random
import statistics
from pathlib import Path

from client import Client
from data import (DEPARTMENTS, FILLER, LANGUAGE_NAMES, LANGUAGES, NEEDLE_QUESTIONS, NEEDLES,
                  TICKET_LABELS, TICKETS, ticket_questions)

OUT = Path("output")
LENGTH_FRACTIONS = [0.03, 0.25, 0.5, 0.97]
POSITIONS = [0.0, 0.25, 0.5, 0.75, 1.0]
LANG_ID_QUESTION = {"language": {"type": "choice", "instructions": "Which language is the state written in?",
                                 "criteria": {code: name for code, name in LANGUAGE_NAMES.items()}}}
PROBE_QUESTION = {"q": {"type": "noul", "instructions": "Is this a warehouse log?"}}


def haystack(lang: str, chars: int, seed: int) -> list[str]:
    """Shuffled filler lines totalling at least `chars` characters (joined with newlines)."""
    rng = random.Random(seed)
    lines, total = [], 0
    while total < chars:
        batch = FILLER[lang][:]
        rng.shuffle(batch)
        for line in batch:
            lines.append(line)
            total += len(line) + 1
            if total >= chars:
                break
    return lines


def text(lang: str, chars: int, seed: int = 0) -> str:
    return "\n".join(haystack(lang, chars, seed))[:chars]


def insert(lines: list[str], line: str, position: float) -> list[str]:
    index = round(position * len(lines))
    return lines[:index] + [line] + lines[index:]


# --- phase 2: does Jev understand each language? -------------------------------------------

def tickets(client: Client, repeats: int) -> dict:
    jobs, keys = [], []
    for lang in LANGUAGES:
        for variant in ("questions_en", "questions_native"):
            questions = ticket_questions("en" if variant == "questions_en" else lang)
            for i, ticket in enumerate(TICKETS[lang]):
                for rep in range(repeats if variant == "questions_native" else 1):
                    jobs.append((ticket, questions))
                    keys.append((lang, variant, i, rep))
        for i, ticket in enumerate(TICKETS[lang]):
            jobs.append((ticket, LANG_ID_QUESTION))
            keys.append((lang, "language_id", i, 0))
    results = client.ask_many(jobs, workers=4)
    bad = [r for r in results if not r.ok]
    if bad:
        raise SystemExit(f"{len(bad)} ticket requests failed, first: {bad[0].status} {bad[0].body}")
    raw: dict = {}
    for (lang, variant, i, rep), r in zip(keys, results):
        raw.setdefault(lang, {}).setdefault(variant, {}).setdefault(i, []).append(r.body["answers"])

    def summarize(lang: str, variant: str) -> dict:
        runs = raw[lang][variant]
        first = {i: runs[i][0] for i in runs}
        english = raw["en"]["questions_en"]
        dept_ok = sum(first[i]["department"]["choice"] == TICKET_LABELS[i][0] for i in first)
        urgent = [(first[i]["urgent"]["noul"] >= 0.5) == TICKET_LABELS[i][1]
                  for i in first if TICKET_LABELS[i][1] is not None]
        frustration_err = [abs(first[i]["frustration"]["score"] - TICKET_LABELS[i][2]) for i in first]
        drift = []
        for i in first:
            en = english[i][0]
            drift += [abs(first[i]["department"]["probabilities"][d] - en["department"]["probabilities"][d])
                      for d in DEPARTMENTS]
            drift.append(abs(first[i]["urgent"]["noul"] - en["urgent"]["noul"]))
        return {
            "department_accuracy": dept_ok / len(first),
            "urgent_accuracy": sum(urgent) / len(urgent),
            "frustration_mae": statistics.mean(frustration_err),
            "mean_abs_diff_vs_english": statistics.mean(drift),
            "department_confidence_mean": statistics.mean(first[i]["department"]["confidence"] for i in first),
        }

    def repeatability(lang: str) -> dict:
        runs = raw[lang]["questions_native"]
        spreads, flips = [], 0
        for answers in runs.values():
            if len(answers) < 2:
                return {}
            flips += len({a["department"]["choice"] for a in answers}) > 1
            spreads += [statistics.pstdev(a["department"]["probabilities"][d] for a in answers) for d in DEPARTMENTS]
            spreads.append(statistics.pstdev(a["urgent"]["noul"] for a in answers))
            spreads.append(statistics.pstdev(a["frustration"]["score"] for a in answers))
        return {"runs": len(next(iter(runs.values()))), "mean_std": statistics.mean(spreads),
                "max_std": max(spreads), "tickets_with_choice_flip": flips}

    summary = {}
    for lang in LANGUAGES:
        ids = raw[lang]["language_id"]
        summary[lang] = {
            "questions_en": summarize(lang, "questions_en"),
            "questions_native": summarize(lang, "questions_native"),
            "language_id_accuracy": sum(ids[i][0]["language"]["choice"] == lang for i in ids) / len(ids),
            "language_id_mistakes": sorted({ids[i][0]["language"]["choice"] for i in ids} - {lang}),
            "repeatability": repeatability(lang),
        }
    return {"summary": summary, "raw": raw}


# --- phase 3: tokens, limit, long context ------------------------------------------------------

def token_density(client: Client) -> dict:
    rows = {}
    for lang in LANGUAGES:
        small, large = client.ask(text(lang, 2_000), PROBE_QUESTION), client.ask(text(lang, 20_000), PROBE_QUESTION)
        chars_per_token = 18_000 / (large.input_tokens - small.input_tokens)
        joined = "\n".join(TICKETS[lang])
        ticket = client.ask(joined, PROBE_QUESTION)
        empty = client.ask("-", PROBE_QUESTION)
        rows[lang] = {
            "filler_chars_per_token": chars_per_token,
            "filler_utf8_bytes_per_char": len(text(lang, 20_000).encode()) / 20_000,
            "tickets_chars": len(joined),
            "tickets_tokens_over_one_char_state": ticket.input_tokens - empty.input_tokens,
            "one_char_state_tokens": empty.input_tokens,
        }
    return rows


def max_state(client: Client, density: dict) -> dict:
    rows = {}
    for lang in LANGUAGES:
        guess = int(33_000 * density[lang]["filler_chars_per_token"])
        lo, hi, tokens = int(guess * 0.8), int(guess * 1.2), 0
        assert client.ask(text(lang, lo), PROBE_QUESTION).ok and not client.ask(text(lang, hi), PROBE_QUESTION).ok
        while hi - lo > max(50, guess // 2000):
            mid = (lo + hi) // 2
            r = client.ask(text(lang, mid), PROBE_QUESTION)
            if r.ok:
                lo, tokens = mid, r.input_tokens
            else:
                hi = mid
        rows[lang] = {"ok_chars": lo, "ok_tokens": tokens, "fail_chars": hi,
                      "ok_utf8_bytes": len(text(lang, lo).encode())}
    return rows


def long_context(client: Client, limits: dict, repeats: int) -> dict:
    jobs, keys = [], []
    for lang in LANGUAGES:
        needle, distractor = NEEDLES[lang]
        for fraction in LENGTH_FRACTIONS:
            chars = int(limits[lang]["ok_chars"] * fraction) - 2 * len(needle) - 4
            for p_index, position in enumerate(POSITIONS):
                base = haystack(lang, chars, seed=p_index)
                distractor_at = POSITIONS[(p_index + 2) % len(POSITIONS)]
                negative = insert(base, distractor, distractor_at)
                positive = insert(negative, needle, position)
                count = repeats if (fraction == LENGTH_FRACTIONS[-1] and position == 0.5) else 1
                for case, lines in (("positive", positive), ("negative", negative)):
                    for rep in range(count):
                        jobs.append(("\n".join(lines), NEEDLE_QUESTIONS))
                        keys.append((lang, fraction, position, case, rep))
    results = client.ask_many(jobs, workers=3)
    rows = []
    for (lang, fraction, position, case, rep), r in zip(keys, results):
        row = {"lang": lang, "fraction": fraction, "position": position, "case": case, "rep": rep,
               "status": r.status, "ms": round(r.ms)}
        if r.ok:
            row |= {"input_tokens": r.input_tokens, "stated": r.answer("stated")["noul"],
                    "code": r.answer("code")["choice"], "code_confidence": r.answer("code")["confidence"]}
        else:
            row["error"] = r.body
        rows.append(row)

    summary = {}
    for lang in LANGUAGES:
        mine = [r for r in rows if r["lang"] == lang and r["rep"] == 0 and r["status"] == 200]
        pos = [r for r in mine if r["case"] == "positive"]
        neg = [r for r in mine if r["case"] == "negative"]
        by_len = {}
        for fraction in LENGTH_FRACTIONS:
            p = [r for r in pos if r["fraction"] == fraction]
            n = [r for r in neg if r["fraction"] == fraction]
            by_len[str(fraction)] = {
                "tokens": round(statistics.mean(r["input_tokens"] for r in p)),
                "positive_stated_mean": statistics.mean(r["stated"] for r in p),
                "negative_stated_mean": statistics.mean(r["stated"] for r in n),
                "code_accuracy": (sum(r["code"] == "4817" for r in p) + sum(r["code"] == "not_stated" for r in n)) / (len(p) + len(n)),
                "median_ms": statistics.median(r["ms"] for r in p + n),
            }
        rep_rows = [r for r in rows if r["lang"] == lang and r["fraction"] == LENGTH_FRACTIONS[-1]
                    and r["position"] == 0.5 and r["case"] == "positive" and r["status"] == 200]
        summary[lang] = {
            "errors": sum(r["status"] != 200 for r in rows if r["lang"] == lang),
            "by_length": by_len,
            "separation_all": min(r["stated"] for r in pos) - max(r["stated"] for r in neg),
            "code_accuracy_all": (sum(r["code"] == "4817" for r in pos) + sum(r["code"] == "not_stated" for r in neg)) / len(mine),
            "near_limit_repeat": {"runs": len(rep_rows),
                                  "stated_std": statistics.pstdev(r["stated"] for r in rep_rows),
                                  "codes": sorted({r["code"] for r in rep_rows})},
        }
    return {"summary": summary, "rows": rows}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repeats", type=int, default=10)
    args = parser.parse_args()
    client = Client()
    OUT.mkdir(exist_ok=True)
    report: dict = {"model": client.ask("x", PROBE_QUESTION).body["model"]}

    report["tickets"] = tickets(client, args.repeats)
    print(json.dumps(report["tickets"]["summary"], indent=1))
    report["token_density"] = token_density(client)
    print(json.dumps(report["token_density"], indent=1))
    report["max_state"] = max_state(client, report["token_density"])
    print(json.dumps(report["max_state"], indent=1))
    report["long_context"] = long_context(client, report["max_state"], args.repeats)
    print(json.dumps(report["long_context"]["summary"], indent=1))
    (OUT / "languages.json").write_text(json.dumps(report, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
