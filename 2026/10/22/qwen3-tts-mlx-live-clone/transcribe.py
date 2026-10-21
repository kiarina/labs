"""Sequential diagnostic ASR after generation; never used as a listening score."""
import argparse
import hashlib
import importlib.metadata
import json
import re
from pathlib import Path
import mlx_whisper
import numpy as np
import soundfile as sf
from scipy.signal import resample_poly
from huggingface_hub import snapshot_download

p=argparse.ArgumentParser();p.add_argument('folders',nargs='+');args=p.parse_args()
repo='mlx-community/whisper-large-v3-turbo';revision='a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb'
path=snapshot_download(repo,revision=revision)
cache={}
for folder in args.folders:
    root=Path(folder);results=[]
    for file in sorted(root.glob('*.wav')):
        if not re.fullmatch(r'(?:full|chars|long_full|long_chars|long_pause)-\d+',file.stem):continue
        audio,sr=sf.read(file,dtype='float32');audio=resample_poly(audio,16000,sr).astype(np.float32)
        digest=hashlib.sha256(audio.tobytes()).hexdigest()
        if digest not in cache:
            cache[digest]=mlx_whisper.transcribe(audio,path_or_hf_repo=path,language='ja',temperature=0.)
        result=cache[digest]
        item={'file':file.name,'audio_16k_sha256':digest,'text':result['text'],'segments':result['segments']};results.append(item)
        print(json.dumps({'folder':root.name,'file':file.name,'text':result['text']},ensure_ascii=False),flush=True)
    (root/'transcripts.json').write_text(json.dumps({'model':repo,'revision':revision,'mlx_whisper':importlib.metadata.version('mlx-whisper'),'results':results},ensure_ascii=False,indent=2))
