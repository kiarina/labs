#!/usr/bin/env python3
"""Same-event offline exploration. This never establishes live/RTP acceptance."""
import argparse,hashlib,json,subprocess
from pathlib import Path
import numpy as np
p=argparse.ArgumentParser();p.add_argument('artifacts',type=Path);p.add_argument('replay_exe',type=Path);p.add_argument('output',type=Path);p.add_argument('--gain',type=int,choices=[1,2,8],default=1);a=p.parse_args();a.output.mkdir(parents=True,exist_ok=True)
x=np.fromfile(a.artifacts/'mixed.pcm','<i2').astype(np.int32);over=int(np.sum((x*a.gain>32767)|(x*a.gain<-32768)))
# preset18 performs the original float x8/output /8 path without pre-clamping.
# gain2 uses an explicitly checked PCM input and baseline processor.
if a.gain==2 and over:raise SystemExit('Gain2 exceeds PCM headroom; no replay')
source=a.artifacts/'mixed.pcm'
if a.gain==2:source=a.output/'input.pcm';(x*2).astype('<i2').tofile(source)
raw=a.output/'dsp.pcm';out=a.output/'output.pcm'
subprocess.run([str(a.replay_exe.resolve()),str(source),str(a.artifacts/'actual_render.pcm'),str(a.artifacts/'dsp-events.bin'),'18' if a.gain==8 else '0',str(raw),'20'],check=True)
y=np.fromfile(raw,'<i2');(np.rint(y.astype(float)/2).astype('<i2') if a.gain==2 else y).tofile(out)
baseline=(a.artifacts/'baseline.pcm').read_bytes()
r={'gainBeforeAec':a.gain,'gainAfterAec':1/a.gain,'nominalInputOverrangeSamples':over,'sameEventOrder':True,'offlineOnly':True,'sha256':hashlib.sha256(out.read_bytes()).hexdigest(),'baselineByteIdentical':out.read_bytes()==baseline if a.gain==1 else None,'adoptedForLive':False}
(a.output/'replay.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r))
