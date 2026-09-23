"""Print Markdown tables from output/*.json and copy the records into results/."""

from __future__ import annotations

import json
import re
from pathlib import Path

HERE = Path(__file__).resolve().parent
OUTPUT = HERE / "output"
RESULTS = HERE / "results"
ORDER = ("full4bit-plemmap",)


def load(model: str, suite: str) -> dict | None:
    path = OUTPUT / f"{model}-{suite}.json"
    return json.loads(path.read_text(encoding="utf-8")) if path.exists() else None


def redact(text: str) -> str:
    """Hide machine-specific paths that tool and test outputs captured."""
    text = re.sub(r"(/private)?/var/folders/[^\"\s]*?/T/tmp[\w]+", "$TMPDIR/tmp", text)
    text = text.replace(str(HERE), ".")
    return text.replace(str(Path.home()), "~")


def rescore_ja() -> None:
    """Re-apply the current checks in data/ja.json to the stored outputs."""
    from eval import DATA, check

    checks = {i["id"]: i["check"] for i in json.loads((DATA / "ja.json").read_text(encoding="utf-8"))}
    for path in OUTPUT.glob("*-ja.json"):
        d = json.loads(path.read_text(encoding="utf-8"))
        by_cat: dict[str, list[bool]] = {}
        for item in d["items"]:
            item["pass"] = check(item["text"], checks[item["id"]])
            by_cat.setdefault(item["category"], []).append(item["pass"])
        d["score"] = sum(i["pass"] for i in d["items"])
        d["by_category"] = {k: f"{sum(v)}/{len(v)}" for k, v in by_cat.items()}
        path.write_text(json.dumps(d, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> None:
    rescore_ja()
    RESULTS.mkdir(exist_ok=True)
    for path in sorted(OUTPUT.glob("*-*.json")):
        (RESULTS / path.name).write_text(redact(path.read_text(encoding="utf-8")), encoding="utf-8")

    print("| Model | Total | Knowledge | Instruction | Reading | Keigo |")
    print("|---|---:|---:|---:|---:|---:|")
    for model in ORDER:
        if d := load(model, "ja"):
            c = d["by_category"]
            print(
                f"| {model} | {d['score']}/{d['total']} | {c['knowledge']} | "
                f"{c['instruction']} | {c['reading']} | {c['keigo']} |"
            )

    print("\n| Model | Target | Prompt tokens | Found (北門/中庭/南塔) | Prefill tok/s | TTFT s | Peak GB |")
    print("|---|---:|---:|---|---:|---:|---:|")
    for model in ORDER:
        # full4bit ran one length per process (tagged files) after an OOM.
        for path in sorted(OUTPUT.glob(f"{model}-needle*.json")):
            d = json.loads(path.read_text(encoding="utf-8"))
            for i in d["items"]:
                hits = "/".join("o" if v else "x" for v in i["hits"].values())
                print(
                    f"| {model} | {i['target_tokens']:,} | {i['prompt_tokens']:,} | {hits} | "
                    f"{i['prompt_tps']:.0f} | {i['ttft_s']:.1f} | {i['peak_gb']:.1f} |"
                )

    print("\n| Model | Task | Success | Visible | Hidden | Tests untouched | Steps | Stop | Max prompt | Time s |")
    print("|---|---|---|---|---|---|---:|---|---:|---:|")
    for model in ORDER:
        if d := load(model, "agent"):
            for i in d["items"]:
                print(
                    f"| {model} | {i['task']} | {i['success']} | {i['visible_pass']} | {i['hidden_pass']} | "
                    f"{i['tests_untouched']} | {i['steps']} | {i['stop']} | {i['max_prompt_tokens']:,} | "
                    f"{i['elapsed_s']:.0f} |"
                )

    print("\n| Model | Load s | Load peak GB | Decode tok/s (ja median) |")
    print("|---|---:|---:|---:|")
    for model in ORDER:
        if d := load(model, "ja"):
            tps = sorted(i["generation_tps"] for i in d["items"])
            print(f"| {model} | {d['load_seconds']:.1f} | {d['load_peak_gb']:.1f} | {tps[len(tps) // 2]:.1f} |")


if __name__ == "__main__":
    main()
