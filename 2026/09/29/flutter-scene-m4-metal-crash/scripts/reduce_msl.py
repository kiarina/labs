"""Shrinks an MSL file while it still crashes the Metal compiler service.

Usage: python3 scripts/reduce_msl.py <input.metal> <output.metal> [--jobs N]

A candidate is kept when probe/probe fails with XPC_ERROR_CONNECTION_INTERRUPTED
(the compiler service died), not when it fails to compile. The passes repeat
until none of them removes anything:

  blocks    delete an if/else chain, loop or bare block as a whole
  flatten   keep a block's body but drop its header and braces
  zero      replace a declaration's initializer with a zero of its type
  lines     delete single statements, in halving chunks (ddmin-like)
  decls     delete struct members, globals and helper functions

The best result so far is written to <output.metal> after every accepted step.
"""
import argparse
import concurrent.futures
import itertools
import os
import re
import subprocess
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PROBE = os.path.join(HERE, "..", "probe", "probe")
SCALAR = re.compile(
    r"^(\s*)((?:float|half|int|uint|bool)(?:[234](?:x[234])?)?)\s+(_\w+)\s*=\s*(.+);\s*$")
tests = 0


def crashes(src):
    global tests
    tests += 1
    fd, path = tempfile.mkstemp(suffix=".metal", dir=WORK)
    with os.fdopen(fd, "w") as f:
        f.write(src)
    try:
        out = subprocess.run([PROBE, path], capture_output=True, text=True,
                             timeout=120).stdout
    except subprocess.TimeoutExpired:
        out = ""
    finally:
        os.unlink(path)
    return "XPC_ERROR_CONNECTION_INTERRUPTED" in out


def zero_of(t):
    if t.startswith("bool"):
        return "false" if t == "bool" else f"{t}(false)"
    return f"{t}(0)"


def main_range(lines):
    start = next(i for i, l in enumerate(lines) if l.startswith("fragment ")
                 or l.startswith("vertex "))
    return start + 2, len(lines) - 1  # inside `{` ... final `}`


def match_brace(lines, i):
    depth = 0
    for j in range(i, len(lines)):
        depth += lines[j].count("{") - lines[j].count("}")
        if depth == 0:
            return j
    return None


def block_candidates(lines):
    lo, hi = main_range(lines)
    out = []
    i = lo
    while i < hi:
        l = lines[i].strip()
        header = None
        if re.match(r"^(if|for|while|switch)\b", l) or l == "do":
            header = i
            body = i + 1 if i + 1 < hi and lines[i + 1].strip() == "{" else None
        elif l == "{":
            header, body = i, i
        else:
            body = None
        if header is not None and body is not None:
            end = match_brace(lines, body)
            if end is not None:
                chain_end = end
                while chain_end + 1 < hi and lines[chain_end + 1].strip().startswith("else"):
                    nxt = chain_end + 2 if lines[chain_end + 2].strip() == "{" else None
                    if lines[chain_end + 1].strip().startswith("else if"):
                        nxt = chain_end + 2
                    if nxt is None or lines[nxt].strip() != "{":
                        break
                    e2 = match_brace(lines, nxt)
                    if e2 is None:
                        break
                    chain_end = e2
                if l.startswith("do"):
                    if chain_end + 1 < hi and lines[chain_end].strip().startswith("} while"):
                        pass
                out.append(("blocks", header, chain_end, body, end))
        i += 1
    # Big blocks first: they shrink the file fastest.
    out.sort(key=lambda c: -(c[2] - c[1]))
    return out


def variants(lines, pass_name):
    lo, hi = main_range(lines)
    if pass_name in ("blocks", "flatten"):
        for _, h, e, b, be in block_candidates(lines):
            if pass_name == "blocks":
                yield lines[:h] + lines[e + 1:]
            elif lines[h].strip() != "{" and be == e:
                yield lines[:h] + lines[b + 1:be] + lines[be + 1:]
            elif lines[h].strip() == "{":
                yield lines[:h] + lines[h + 1:e] + lines[e + 1:]
    elif pass_name == "zero":
        for i in range(hi - 1, lo - 1, -1):
            m = SCALAR.match(lines[i])
            if m and m.group(4).strip() != zero_of(m.group(2)):
                ind, t, name, _ = m.groups()
                yield lines[:i] + [f"{ind}{t} {name} = {zero_of(t)};"] + lines[i + 1:]
    elif pass_name == "lines":
        idx = [i for i in range(lo, hi) if lines[i].rstrip().endswith(";")]
        n = len(idx)
        chunk = max(n // 2, 1)
        while chunk >= 1:
            for s in range(0, n, chunk):
                drop = set(idx[s:s + chunk])
                yield [l for i, l in enumerate(lines) if i not in drop]
            chunk //= 2
    elif pass_name == "decls":
        start = main_range(lines)[0] - 2
        for i in range(start - 1, -1, -1):
            l = lines[i]
            if l.rstrip().endswith(";") and not l.startswith("#"):
                yield lines[:i] + lines[i + 1:]
            elif l.strip() == "{":
                end = match_brace(lines, i)
                if end is not None and end < start:
                    top = i - 1
                    while top > 0 and lines[top - 1].startswith("template"):
                        top -= 1
                    yield lines[:top] + lines[end + 1:]


def run_pass(lines, pass_name, jobs):
    """Accepts the first crashing variant of each batch. After an accepted
    step the pass resumes where it was instead of retrying the candidates that
    already failed; the outer loop runs every pass again until nothing moves."""
    changed = False
    skip = 0
    while True:
        gen = itertools.islice(variants(lines, pass_name), skip, None)
        accepted = None
        tried = skip
        with concurrent.futures.ThreadPoolExecutor(jobs) as ex:
            while accepted is None:
                batch = list(itertools.islice(gen, jobs))
                if not batch:
                    break
                results = list(ex.map(lambda v: crashes("\n".join(v) + "\n"), batch))
                for v, ok in zip(batch, results):
                    if ok:
                        accepted = v
                        break
                    tried += 1
        if accepted is None:
            return lines, changed
        lines, changed = accepted, True
        skip = tried
        save(lines)
        log(f"{pass_name}: {len(lines)} lines")


def save(lines):
    with open(OUTPUT, "w") as f:
        f.write("\n".join(lines) + "\n")


def log(msg):
    print(f"[{time.strftime('%H:%M:%S')}] tests={tests} {msg}", flush=True)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--jobs", type=int, default=8)
    a = ap.parse_args()
    OUTPUT = a.output
    WORK = tempfile.mkdtemp(prefix="reduce_msl_")
    lines = open(a.input).read().rstrip("\n").split("\n")
    assert crashes("\n".join(lines) + "\n"), "the input does not crash"
    log(f"start: {len(lines)} lines")
    while True:
        progress = False
        for p in ("blocks", "flatten", "zero", "lines", "decls"):
            lines, changed = run_pass(lines, p, a.jobs)
            progress |= changed
        if not progress:
            break
    save(lines)
    log(f"done: {len(lines)} lines")
