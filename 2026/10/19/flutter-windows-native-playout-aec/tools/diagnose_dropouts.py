#!/usr/bin/env python3
"""Separate raw-to-DSP attenuation from DSP-to-decoder delivery diagnostics."""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
from scipy import signal

p=argparse.ArgumentParser()
p.add_argument('artifacts',type=Path)
p.add_argument('received',type=Path)
p.add_argument('output',type=Path)
p.add_argument('--variant',default='baseline',choices=['baseline','conditioned'])
a=p.parse_args()
r=json.loads((a.artifacts/'report.json').read_text())
x=np.fromfile(a.artifacts/'raw.pcm','<i2').astype(float)
y=np.fromfile(a.artifacts/(a.variant+'.pcm'),'<i2').astype(float)
z=np.fromfile(a.received,'<i2').astype(float)
def db(v): return float(20*np.log10(max(float(v),1e-12)))
def rms(v):return np.sqrt(np.mean(v*v))
rows=[]
for q in r['phases']:
 if q['name'] not in ['near-only','doubletalk-1','doubletalk-2','near-recovery']:continue
 s=q['start']['rawBytes']//2;e=q['end']['rawBytes']//2
 raw=x[s:e];dsp=y[s:e];rx=z[q['peerStart']['samples']:q['peerEnd']['samples']]
 # Only search within this gate. The receiver may contain gate onset PLC/idle samples.
 corr=signal.correlate(rx,dsp,method='fft');lags=signal.correlation_lags(len(rx),len(dsp));valid=abs(lags)<24000
 lag=int(lags[valid][np.argmax(corr[valid])]);windows=[]
 for t in range(48000,min(len(raw),len(dsp))-24000,4800):
  inp=raw[t:t+4800];out=dsp[t+432:t+432+4800]
  if len(out)!=4800 or db(rms(inp)/32768)<-65:continue
  source=dsp[t:t+4800];k=t+lag;lo=max(0,k-2400);hi=min(len(rx),k+4800+2400);search=rx[lo:hi]
  if len(search)<4800:continue
  cross=signal.correlate(search,source,mode='valid',method='fft')
  sums=np.r_[0,np.cumsum(search*search)];energy=sums[4800:]-sums[:-4800]
  norm=cross/np.sqrt(np.maximum(energy*np.dot(source,source),1e-20));best=int(np.argmax(norm));dest=search[best:best+4800]
  windows.append({'secondsInPhase':t/48000,'rawDbfs':db(rms(inp)/32768),'aecRmsGainDb':db(rms(out)/max(rms(inp),1e-12)),
    'receiverCorrelationLocal':float(norm[best]),'receiverRmsGainDb':db(rms(dest)/max(rms(source),1e-12)),'receiverAlignmentAdjustmentSamples':lo+best-k})
 rows.append({'phase':q['name'],'receiverLagSamples':lag,'active100msWindows':len(windows),
 'aecWindowsBelowMinus6Db':sum(w['aecRmsGainDb']<-6 for w in windows),'aecWorstGainDb':min(w['aecRmsGainDb'] for w in windows),
 'receiverWindowsBelowMinus12Db':sum(w['receiverRmsGainDb']<-12 for w in windows),
 'receiverMedianCorrelation':float(np.median([w['receiverCorrelationLocal'] for w in windows])), 'windows':windows})
result={'kind':'dropout-localization','variant':a.variant,'session':r['session'],'rawActivityThresholdDbfs':-65,'dspDelaySamples':432,'analysisWindowMs':100,'phases':rows,
'clipEdit':{'combinedDoubletalkEditSeconds':6,'recommendation':'Listen to doubletalk-1 and doubletalk-2 separately.'},
'caveats':['Total raw input ratios are not isolated near-speech gain.','Local decoder alignment allows +/-50ms; report corrections, do not treat them as a fixed end-to-end latency.','Original callback maximum104.568ms has no position; capture gaps cannot be excluded.'],
'inputSha256':{n:hashlib.sha256((a.artifacts/(n+'.pcm')).read_bytes()).hexdigest() for n in ['raw',a.variant]}}
a.output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps([{k:v for k,v in row.items() if k!='windows'} for row in rows],indent=2))
