"""Turn the example app's `PCM_ASR {...}` log lines into results/<name>.json
and check them against fixtures/segments.json.

usage: python3 tools/evaluate.py <name> <log file> [--known-limit <case> ...]

`--known-limit` names an error-path check that the platform cannot satisfy
(for example the Web cannot reject an unknown locale before sending audio);
it is recorded in the summary and excluded from `pass`.

Checks: every segment of every pass has a non-empty result with the request ID
echoed back; normalized CER against the reference text; request time median,
p95 and first-request value; the three error-path checks passed.
"""
import json
import statistics
import sys
import unicodedata
from pathlib import Path

root = Path(__file__).resolve().parents[1]
name, log_path = sys.argv[1], Path(sys.argv[2])
known_limits = [a for a in sys.argv[4:] if sys.argv[3:4] == ['--known-limit']] if len(sys.argv) > 3 else []
segments = {s['id']: s for s in json.loads((root / 'fixtures/segments.json').read_text())}
events = []
for line in log_path.read_text(errors='replace').splitlines():
    marker = line.find('PCM_ASR {')
    if marker >= 0:
        events.append(json.loads(line[marker + len('PCM_ASR '):]))


def normalize(text):
    text = unicodedata.normalize('NFKC', text).lower()
    return ''.join(ch for ch in text if not ch.isspace() and not unicodedata.category(ch).startswith('P'))


def edit_distance(a, b):
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1]


results = [e for e in events if e['kind'] == 'result']
errors = [e for e in events if e['kind'] == 'error']
checks = {e['case']: e for e in events if e['kind'] == 'error_check'}
support = next((e for e in events if e['kind'] == 'support'), None)
prepare = next((e for e in events if e['kind'] == 'prepare'), None)
done = next((e for e in events if e['kind'] == 'done'), None)
platform = next((e for e in events if e['kind'] == 'platform'), None)

expected = len(segments) * 3
nonempty = sum(1 for r in results if r['text'])
id_ok = sum(1 for r in results if r['id_matches'])
dist = ref_len = 0
per_segment = {}
for r in results:
    ref = normalize(segments[r['segment_id']]['reference'])
    hyp = normalize(r['text'])
    d = edit_distance(hyp, ref)
    dist += d
    ref_len += len(ref)
    per_segment.setdefault(r['segment_id'], []).append({'trial': r['trial'], 'text': r['text'], 'distance': d, 'elapsed_ms': r['elapsed_ms']})
elapsed = [r['elapsed_ms'] for r in results]
summary = {
    'name': name,
    'platform': platform,
    'support': support,
    'prepare': prepare,
    'expected_results': expected,
    'results': len(results),
    'errors': errors,
    'non_empty': nonempty,
    'id_matches': id_ok,
    'cer': round(dist / ref_len, 4) if ref_len else None,
    'cer_detail': f'{dist}/{ref_len}',
    'elapsed_ms': {
        'first': elapsed[0] if elapsed else None,
        'median': round(statistics.median(elapsed), 1) if elapsed else None,
        'p95': round(sorted(elapsed)[max(0, int(len(elapsed) * 0.95) - 1)], 1) if elapsed else None,
        'max': max(elapsed) if elapsed else None,
        'median_after_first': round(statistics.median(elapsed[1:]), 1) if len(elapsed) > 1 else None,
    },
    'round_trip_ms_median': round(statistics.median([r['round_trip_ms'] for r in results]), 1) if results else None,
    'error_checks': {k: {'ok': v.get('ok'), **{x: v[x] for x in v if x not in ('kind', 'case', 'ok')}} for k, v in checks.items()},
    'known_limits': known_limits,
    'per_segment': per_segment,
    'done': done,
}
summary['pass'] = bool(
    done and done.get('ok') and len(results) == expected and nonempty == expected and id_ok == expected
    and not errors and all(c.get('ok') or k in known_limits for k, c in checks.items()) and len(checks) == 3
)
out = root / 'results' / f'{name}.json'
out.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: summary[k] for k in ('name', 'pass', 'results', 'non_empty', 'id_matches', 'cer', 'elapsed_ms', 'error_checks')}, ensure_ascii=False, indent=2))
sys.exit(0 if summary['pass'] else 1)
