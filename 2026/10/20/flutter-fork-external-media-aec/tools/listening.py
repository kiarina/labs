#!/usr/bin/env python3
"""Private decoded-receiver listening clips with one common gain."""
import argparse,json,wave
from pathlib import Path
import numpy as np
p=argparse.ArgumentParser();p.add_argument('report',type=Path);p.add_argument('received',type=Path);p.add_argument('output',type=Path);p.add_argument('--max-gain',type=float,default=4);a=p.parse_args();r=json.loads(a.report.read_text());received=np.fromfile(a.received,'<i2').astype(float);ph={q['name']:q for q in r['phases']};clips={}
for name in ['near-only','doubletalk-1','doubletalk-2','near-recovery']:
 q=ph[name];s=q['peerStart']['samples']+48000;e=min(q['peerEnd']['samples']-12000,s+6*48000,len(received));assert e>s
 clips[name]=received[s:e]
clips['doubletalk']=np.concatenate([clips['doubletalk-1'],clips['doubletalk-2']])
peak=max(float(np.max(np.abs(v))) for v in clips.values());gain=min(a.max_gain,.9*32767/max(peak,1));a.output.mkdir(parents=True,exist_ok=True)
for name,v in clips.items():
 with wave.open(str(a.output/(name+'.wav')),'wb') as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(48000);w.writeframes(np.round(np.clip(v*gain,-32768,32767)).astype('<i2').tobytes())
(a.output/'clips.json').write_text(json.dumps({'commonGain':gain,'decodedReceiver':True,'sampleRate':48000,'clips':{name:len(v)/48000 for name,v in clips.items()},'caveat':'Clip/gate boundaries are edits, not evidence of live missing syllables.'},indent=2)+'\n')
print(json.dumps({'gain':gain,'seconds':{name:len(v)/48000 for name,v in clips.items()}}))
