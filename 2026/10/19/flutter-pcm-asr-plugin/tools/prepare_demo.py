"""Checksum-pinned analysis models and the shared conversation for demo/."""
import hashlib
import json
import subprocess
import urllib.request
from pathlib import Path

root = Path(__file__).resolve().parents[1]
assets = root / 'demo/assets'
(assets / 'models').mkdir(parents=True, exist_ok=True)
names = {'silero-vad': 'silero_vad.onnx', 'pyannote-segmentation-3.0': 'model.onnx', 'ecapa-tdnn-onnx': 'ecapa_tdnn.onnx'}
for row in json.loads((root / 'fixtures/live-models.json').read_text()):
    target = assets / 'models' / names[row['name']]
    if not target.exists():
        urllib.request.urlretrieve(row.get('pinned_url', row['url']), target)
    assert hashlib.sha256(target.read_bytes()).hexdigest() == row['sha256'], row['name']
source = root.parents[3] / 'tests/assets/mp3/conversation_2speaker_14s_16k.mp3'
subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', str(source), '-ar', '16000', '-ac', '1', '-c:a', 'pcm_s16le',
                str(assets / 'conversation.wav')], check=True)
print('demo assets ready')
