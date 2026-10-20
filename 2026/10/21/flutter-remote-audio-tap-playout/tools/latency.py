#!/usr/bin/env python3
"""Added playout latency per slot mode from the 250 ms samples of the app:
received-but-not-returned (external processor backlog) + returned-not-played."""
import json, sys, statistics as st
r = json.load(open(sys.argv[1]))
out = {}
for m in sorted({x['mode'] for x in r['latencySamples']}):
    xs = [((x['externalPending'] or 0) + (x['queued'] or 0)) / 48 for x in r['latencySamples'] if x['mode'] == m]
    pend = [(x['externalPending'] or 0) / 48 for x in r['latencySamples'] if x['mode'] == m]
    xs.sort()
    out[m] = {'samples': len(xs), 'medianMs': st.median(xs), 'p95Ms': xs[int(len(xs) * .95) - 1], 'maxMs': xs[-1],
              'processorBacklogMedianMs': st.median(pend)}
print(json.dumps(out, indent=1))
