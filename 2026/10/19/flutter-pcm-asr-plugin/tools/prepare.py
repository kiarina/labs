"""Cut the shared two-speaker conversation into the six SCD segments the
earlier lab used, as raw PCM16 assets for the example app.

Output (git-ignored): pcm_asr/example/assets/segments/segment-N.pcm and
pcm_asr/example/assets/segments/segments.json. The committed
fixtures/segments.json records the same cut points, reference text and hashes.
"""
import hashlib
import json
import subprocess
import wave
from pathlib import Path

root = Path(__file__).resolve().parents[1]
work = root / 'work'
work.mkdir(exist_ok=True)
assets = root / 'pcm_asr/example/assets/segments'
assets.mkdir(parents=True, exist_ok=True)
source = root.parents[3] / 'tests/assets/mp3/conversation_2speaker_14s_16k.mp3'
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(source), '-ar', '16000', '-ac', '1',
                '-c:a', 'pcm_s16le', str(work / 'source.wav')], check=True)
with wave.open(str(work / 'source.wav')) as w:
    pcm = w.readframes(w.getnframes())
assert hashlib.sha256(pcm).hexdigest() == 'aef288721e2f461c844ef766264cbcf09d997baf34fd72872faaebf0618dd06e'
refs = json.loads((root / 'fixtures/scd.json').read_text())
texts = (root / 'fixtures/reference.txt').read_text().splitlines()
rows = []
for i, (r, text) in enumerate(zip(refs, texts)):
    a = round(r['start'] * 16000)
    b = round(r['end'] * 16000)
    raw = pcm[a * 2:b * 2]
    name = f'segment-{i + 1}.pcm'
    (assets / name).write_bytes(raw)
    rows.append({'id': f'segment-{i + 1}', 'speaker_id': f'speaker-{r["speaker"] + 1}', 'start': a / 16000,
                 'end': b / 16000, 'file': name, 'sample_rate': 16000, 'channels': 1, 'reference': text,
                 'samples': b - a, 'pcm_sha256': hashlib.sha256(raw).hexdigest()})
(assets / 'segments.json').write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
(root / 'fixtures/segments.json').write_text(
    json.dumps([{k: v for k, v in row.items() if k != 'file'} for row in rows], ensure_ascii=False, indent=2) + '\n')
print(f'{len(rows)} segments written to {assets.relative_to(root)}')
