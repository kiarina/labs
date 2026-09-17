"""Print a compact summary from output/commands.json and output/moderation.json.

Read-only; makes no API calls. Run after run_commands.py and run_moderation.py.
"""

import json
from pathlib import Path

OUT = Path("output")


def commands_summary() -> None:
    path = OUT / "commands.json"
    if not path.exists():
        print("commands.json not found; run run_commands.py first.")
        return
    r = json.loads(path.read_text())
    print(f"## Commands (n={r['n']}, {r['model']}, median {r['latency_ms_median']:.0f}ms)")
    for name, m in r["summary"].items():
        print(f"  {name:14} exact={m['exact_accuracy']:.3f} gate_recall={m['gate_recall']:.3f} "
              f"gate_precision={m['gate_precision']:.3f} danger_autorun={m['danger_autorun']}")
    d = r["danger_detection"]
    print(f"  danger detection: AP={d['average_precision']:.3f} AUROC={d['roc_auc']:.3f}")
    print(f"  context flips: {len(r['context_flips'])}")


def moderation_summary() -> None:
    path = OUT / "moderation.json"
    if not path.exists():
        print("moderation.json not found; run run_moderation.py first.")
        return
    r = json.loads(path.read_text())
    for lang, d in r.items():
        print(f"## Moderation [{lang}] (n={d['n']}, flagged {d['flagged_rate']:.1%}, "
              f"Jev median {d['jev_latency_ms_median']:.0f}ms)")
        for who in ("jev", "openai"):
            m = d[who]
            print(f"  {who:7} AP={m['average_precision']:.3f} AUROC={m['roc_auc']:.3f} "
                  f"F1@.5={m['at_0.5']['f1']:.3f} recall@.5={m['at_0.5']['recall']:.3f} "
                  f"prec@.5={m['at_0.5']['precision']:.3f} ECE={m['ece']:.3f}")


if __name__ == "__main__":
    commands_summary()
    print()
    moderation_summary()
