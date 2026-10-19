#!/usr/bin/env python3
"""Checksum-pinned live analysis assets, self-contained in this lab."""
import hashlib,json,subprocess,urllib.request
from pathlib import Path
root=Path(__file__).resolve().parents[1];assets=root/'app/assets';(assets/'models').mkdir(parents=True,exist_ok=True)
for row in json.loads((root/'fixtures/live-models.json').read_text()):
 name={'silero-vad':'silero_vad.onnx','pyannote-segmentation-3.0':'model.onnx','ecapa-tdnn-onnx':'ecapa_tdnn.onnx'}[row['name']];target=assets/'models'/name
 if not target.exists():urllib.request.urlretrieve(row.get('pinned_url',row['url']),target)
 assert hashlib.sha256(target.read_bytes()).hexdigest()==row['sha256'],name
source=root.parents[3]/'tests/assets/mp3/conversation_2speaker_14s_16k.mp3'
subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(source),'-ar','16000','-ac','1','-c:a','pcm_s16le',str(assets/'conversation.wav')],check=True)
