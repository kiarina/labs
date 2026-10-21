"""Render recorded PCM arrival timing, with startup and underrun silence."""
import argparse
import json
from pathlib import Path
import numpy as np
import soundfile as sf
p=argparse.ArgumentParser();p.add_argument('folder');p.add_argument('stem');args=p.parse_args()
root=Path(args.folder);r=json.loads((root/f'{args.stem}.json').read_text());audio,sr=sf.read(root/f'{args.stem}.wav',dtype='float32')
pieces=[];cursor=0;end=0
for e in r['events']:
    if e['type']!='pcm':continue
    start=max(round(e['t']*sr),end)
    if start>end:pieces.append(np.zeros(start-end,dtype=np.float32))
    n=e['samples'];pieces.append(audio[cursor:cursor+n]);cursor+=n;end=start+n
assert cursor==len(audio)
sf.write(root/f'{args.stem}-arrival-replay.wav',np.concatenate(pieces),sr,subtype='FLOAT')
