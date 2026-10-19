#!/usr/bin/env python3
"""Same-input known-near short-window retention; not a human near reference."""
import argparse,json
from pathlib import Path
import numpy as np
from scipy.signal import correlate,correlation_lags
p=argparse.ArgumentParser();p.add_argument('artifacts',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
r=json.loads((a.artifacts/'report.json').read_text());assert not r['humanNear'];target=np.fromfile(a.artifacts/'near.pcm','<i2').astype(float);rows=[]
for name in ['baseline','conditioned']:
 out=np.fromfile(a.artifacts/(name+'.pcm'),'<i2').astype(float);q=next(t for t in r['phases'] if t['name']=='near-only');s=q['start']['rawBytes']//2+48000;e=q['end']['rawBytes']//2
 c=correlate(out[s:e],target[s:e],method='fft');lags=correlation_lags(e-s,e-s);valid=(lags>=0)&(lags<=960);lag=int(lags[valid][np.argmax(c[valid])]);phases=[]
 for q in r['phases']:
  if not q['nearExpected']:continue
  s=q['start']['rawBytes']//2+48000;e=min(q['end']['rawBytes']//2-24000,len(out)-lag);gains=[];longest=run=0
  for t in range(s,e-4800+1,4800):
   x=target[t:t+4800];y=out[t+lag:t+lag+4800];power=np.dot(x,x)
   if np.sqrt(power/4800)<20:run=0;continue
   gain=float(np.dot(x,y)/power);gdb=float(20*np.log10(max(gain,1e-12)));gains.append(gdb);run=run+1 if gdb<-6 else 0;longest=max(longest,run)
  phases.append({'name':q['name'],'active100msWindows':len(gains),'minimumSignedProjectionGainDb':min(gains) if gains else None,'windowsBelowMinus6Db':sum(g<-6 for g in gains),'longestRunBelowMinus6DbMs':longest*100})
 rows.append({'variant':name,'lag':lag,'phases':phases})
result={'kind':'known-near-short-window-retention','activeTargetRmsMinimum':20,'variants':rows,'candidateNoLossPass':all(q['active100msWindows'] and q['windowsBelowMinus6Db']==0 for q in rows[1]['phases']),'caveat':'Known capture-only speech mixed with real mic; not physical human near or proof of acoustic echo rejection.'}
a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
