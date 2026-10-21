"""Diagnostic ASR only; not a listening or prosody quality rating."""
import argparse
import importlib.metadata
import json
from pathlib import Path
import mlx_whisper
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
from huggingface_hub import snapshot_download

parser=argparse.ArgumentParser()
parser.add_argument('--output',default='../output')
args=parser.parse_args()
output=Path(args.output)
repo='mlx-community/whisper-large-v3-turbo'
rev='a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb'
model=snapshot_download(repo,revision=rev)
results=[]
for file in sorted(output.glob('*.wav')):
    if file.stem.endswith('-arrival-replay'): continue
    audio,sr=sf.read(file,dtype='float32')
    audio=resample_poly(audio,16000,sr).astype(np.float32)
    r=mlx_whisper.transcribe(audio,path_or_hf_repo=model,language='ja' if file.name.startswith('ja') else 'en',temperature=0.0)
    item={'file':file.name,'text':r['text'],'segments':r['segments']}
    results.append(item)
    print(json.dumps({'file':file.name,'text':r['text']},ensure_ascii=False),flush=True)
(output/'transcripts.json').write_text(json.dumps({'model':repo,'revision':rev,'mlx_whisper':importlib.metadata.version('mlx-whisper'),'results':results},indent=2,ensure_ascii=False))
