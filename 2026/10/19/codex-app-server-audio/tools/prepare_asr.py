#!/usr/bin/env python3
"""Prepare checksum-pinned ASR analysis weights and the shared speech fixture."""
import hashlib,json,subprocess,urllib.request,wave
from pathlib import Path
root=Path(__file__).resolve().parents[1];assets=root/'asr/app/assets';(assets/'models').mkdir(parents=True,exist_ok=True)
for m in json.loads((root/'fixtures/asr-models.json').read_text()):
 filename={'silero-vad':'silero_vad.onnx','pyannote-segmentation-3.0':'model.onnx','ecapa-tdnn-onnx':'ecapa_tdnn.onnx'}[m['name']];p=assets/'models'/filename
 if not p.exists():
  with urllib.request.urlopen(m.get('pinned_url',m['url'])) as response:p.write_bytes(response.read())
 assert hashlib.sha256(p.read_bytes()).hexdigest()==m['sha256'],filename
source=root.parents[3]/'tests/assets/mp3/conversation_2speaker_14s_16k.mp3'
subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(source),'-ar','16000','-ac','1','-c:a','pcm_s16le',str(assets/'conversation.wav')],check=True)

with wave.open(str(assets/"conversation.wav"),"rb") as wav:
 assert wav.getframerate()==16000 and wav.getnchannels()==1
 assert hashlib.sha256(wav.readframes(wav.getnframes())).hexdigest()=="aef288721e2f461c844ef766264cbcf09d997baf34fd72872faaebf0618dd06e"

# Every Flutter entrypoint shares one asset manifest. Keep its optional offline
# control fixture available on a clean checkout as well.
if not (assets/"refine-third.wav").exists():
 import sys
 subprocess.run([sys.executable,str(root/"tools/prepare_refinement.py")],check=True)
