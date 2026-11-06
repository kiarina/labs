"""Summarizes results/<prefix>-*.json into one table (markdown) on stdout.
    python3 scripts/summarize.py macos
"""
import glob, json, os, statistics, sys
from collections import defaultdict

prefix = sys.argv[1]
rows = defaultdict(list)
for f in sorted(glob.glob(f"results/{prefix}-*.json")):
    d = json.load(open(f))
    name = os.path.basename(f)[len(prefix) + 1:-5]
    impl, echo, role, end, n = name.rsplit("-", 4)
    rows[(impl, echo, role, end)].append(d)

def med(xs):
    xs = [x for x in xs if x is not None]
    return f"{statistics.median(xs):.2f}" if xs else "-"

print("| impl | echo | probe role | end | ok / runs | open ms | RTT median ms | 1 MiB echo ms | burst MB/s | split-pair cases equal | remote gone (ms, first sign) | failure |")
print("|---|---|---|---|---|---|---|---|---|---|---|---|")
for (impl, echo, role, end), ds in rows.items():
    ok = sum(1 for d in ds if d.get("ok"))
    c = [d.get("checks", {}) for d in ds]
    opens = [x.get("open", {}).get("ms_from_peer_present") for x in c]
    rtt = [x.get("rtt_small", {}).get("median_ms") for x in c]
    mib = [next((s["ms"] for s in x.get("sizes", {}).get("cases", []) if s["chars"] == 1048576), None) for x in c]
    burst = [x.get("burst", {}).get("mb_per_s_each_way") for x in c]
    split = sorted({str(x.get("sizes", {}).get("split_cases_equal")) for x in c if "sizes" in x})
    gone = [f'{x["remote_gone"]["ms"]} {x["remote_gone"]["first_sign"]}' for x in c if x.get("remote_gone", {}).get("ok")]
    errs = sorted({(d.get("error") or "").split("\n")[0][:90] for d in ds if not d.get("ok")})
    print(f"| {impl} | {echo} | {role} | {end} | {ok}/{len(ds)} | {med(opens)} | {med(rtt)} | {med(mib)} | {med(burst)} | {', '.join(split) or '-'} | {'; '.join(gone) or '-'} | {'; '.join(errs) or '-'} |")
