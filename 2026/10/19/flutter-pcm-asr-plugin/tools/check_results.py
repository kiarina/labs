"""Re-validate results/*.json without running any engine."""
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
ok = True
for path in sorted((root / 'results').glob('*.json')):
    s = json.loads(path.read_text())
    line = f"{s['name']}: pass={s['pass']} results={s['results']}/{s['expected_results']} cer={s['cer']} median={s['elapsed_ms']['median']}ms p95={s['elapsed_ms']['p95']}ms"
    print(line)
    ok &= bool(s['pass'])
sys.exit(0 if ok else 1)
