#!/usr/bin/env python3
"""Analyze local-only Web acoustic-probe PCM artifacts. Requires NumPy and SciPy.

Usage: uv run --with numpy --with scipy python tools/web/analyze_acoustics.py
       ARTIFACT_DIR OUTPUT_JSON
Artifact names: report.json, raw.pcm, clean.pcm, mixed.pcm, near.pcm, reference.pcm.
Only metrics and SHA256 are written to the result; microphone PCM stays local.
"""
import hashlib,json,pathlib,sys
import numpy as np
from scipy.signal import correlate,correlation_lags
root=pathlib.Path(sys.argv[1]);report=json.loads((root/'report.json').read_text())
data={name:np.fromfile(root/(name+'.pcm'),dtype='<i2').astype(float) for name in ['raw','clean']}
for name in ['mixed','near','reference','actual_render']:
 if (root/(name+'.pcm')).exists():data[name]=np.fromfile(root/(name+'.pcm'),dtype='<i2').astype(float)
def rms(x):return float(np.sqrt(np.mean(x*x))) if len(x) else 0
def db(value):return float(20*np.log10(max(value,1e-12)))
rows=[];near_lag=None;render_lag=None
if 'actual_render' in data:
 c=correlate(data['raw'],data['actual_render'],method='fft');lags=correlation_lags(len(data['raw']),len(data['actual_render']));valid=abs(lags)<=48000*3
 render_lag=int(lags[valid][np.argmax(abs(c[valid]))])
def projection(signal,reference,begin,end,center):
 segment=signal[begin:min(end,len(signal))]
 c=correlate(segment,reference,method='fft');lags=correlation_lags(len(segment),len(reference))+begin
 valid=abs(lags-center)<=2400
 lag=int(lags[valid][np.argmax(abs(c[valid]))])
 lo=max(begin,lag);hi=min(end,len(signal),len(reference)+lag)
 y=signal[lo:hi];x=reference[lo-lag:hi-lag]
 gain=float(np.dot(y,x)/max(np.dot(x,x),1e-12));corr=float(np.dot(y,x)/max(np.linalg.norm(y)*np.linalg.norm(x),1e-12))
 return {'lagSamples':lag,'gain':gain,'correlation':corr,'projectedRmsDbfs':db(abs(gain)*rms(x)/32768)}
for phase in report['phases']:
 # Discard the first second to exclude old speaker/hardware-buffer tail.
 begin=phase['start']['rawByte']//2+48000;end=phase['end']['rawByte']//2
 x=data['raw'][begin:end];y=data['clean'][begin:min(end,len(data['clean']))]
 row={'name':phase['name'],'secondsAnalyzed':len(y)/48000,'rawRmsDbfs':db(rms(x)/32768),'cleanRmsDbfs':db(rms(y)/32768),'rmsAttenuationDb':db(rms(x)/max(rms(y),1e-12)),
      'rawDcMean':float(np.mean(x)),'rawPeak':float(np.max(abs(x))),
      'rawClipped32700Fraction':float(np.mean(abs(x)>=32700)),
      'rawPeak26027Fraction':float(np.mean(abs(x)==26027))}
 if phase.get('speakerSignal') and render_lag is not None:
  p_raw=projection(data['raw'],data['actual_render'],begin,end,render_lag)
  p_clean=projection(data['clean'],data['actual_render'],begin,end,render_lag+432)
  row.update(rawRenderProjection=p_raw,cleanRenderProjection=p_clean,correlatedEchoReductionDb=db(abs(p_raw['gain'])/max(abs(p_clean['gain']),1e-12)))
 if phase.get('digitalNearEnd') and 'near' in data:
  n=data['near'][begin:begin+len(y)]
  if near_lag is None:
   c=correlate(y,n,method='fft');lags=correlation_lags(len(y),len(n));valid=abs(lags)<=4800
   near_lag=int(lags[valid][np.argmax(abs(c[valid]))])
  lag=near_lag
  if lag>=0:yy=y[lag:];nn=n[:len(yy)]
  else:nn=n[-lag:];yy=y[:len(nn)]
  gain=float(np.dot(yy,nn)/max(np.dot(nn,nn),1e-12))
  row.update(nearAlignmentSamples=lag,nearSignedGain=gain,nearGainDb=db(abs(gain)),nearReferenceRmsDbfs=db(rms(nn)/32768))
 s=phase['endStats'];row['estimatedContextQueuedMs']=(s['renderSubmittedSamples']-s['renderedSamples']+s['underrunSamples'])/48
 rows.append(row)
report['analysis']={'method':'RMS comparison excludes first second; near matched projection uses near-only alignment for doubletalk. Physical RMS attenuation is not ERLE and includes ambient noise.',
 'globalRenderLagSamples':render_lag,'phases':rows,'artifactsSha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in root.glob('*.pcm')}}
pathlib.Path(sys.argv[2]).write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(rows,indent=2))
