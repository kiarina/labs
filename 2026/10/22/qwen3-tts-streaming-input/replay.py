"""Render an idealized unbuffered playback timeline, including startup/gaps."""
import argparse
import json
from pathlib import Path
import numpy as np
import soundfile as sf

parser=argparse.ArgumentParser()
parser.add_argument('stems',nargs='+')
parser.add_argument('--output',default='output')
args=parser.parse_args()
root=Path(args.output)
for stem in args.stems:
    result=json.loads((root/f'{stem}.json').read_text())
    audio,sr=sf.read(root/f'{stem}.wav',dtype='float32')
    offset=0; end=0; pieces=[]
    for event in result['events']:
        if event['type']!='pcm': continue
        start=max(round(event['received']*sr),end)
        if start>end: pieces.append(np.zeros(start-end,dtype=np.float32))
        n=event['samples'];pieces.append(audio[offset:offset+n]);offset+=n;end=start+n
    assert offset==len(audio)
    sf.write(root/f'{stem}-arrival-replay.wav',np.concatenate(pieces),sr,subtype='FLOAT')
    print(stem,end/sr)
