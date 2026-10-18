#!/usr/bin/env python3
"""Version2: calibration mask, held-out DT, per-window validity and near floor."""
import argparse,hashlib,json,pathlib
import numpy as np
from scipy.signal import welch,csd,correlate,correlation_lags
p=argparse.ArgumentParser();p.add_argument('artifacts',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);p.add_argument('--candidate',choices=['baseline','candidate80','candidate100','candidate120','candidate160','long80','long100','strict80']);a=p.parse_args()
def load(name):
 path=a.artifacts/(name+'.pcm')
 if not path.exists():path=a.artifacts/('aec_'+name+'.pcm')
 return np.fromfile(path,'<i2').astype(float)
rpath=a.artifacts/'report.json'
if not rpath.exists():rpath=a.artifacts/'aec_result.json'
r=json.loads(rpath.read_text());raw=load('raw');near=load('near');render=load('actual_render')
names=['baseline','candidate80','candidate100','candidate120','candidate160','long80','long100','strict80']
outputs={n:load(n) for n in names if (a.artifacts/(n+'.pcm')).exists() or (a.artifacts/('aec_'+n+'.pcm')).exists()}
assert 'baseline' in outputs and len(outputs)>=4
phases={q['name']:q for q in r['phases']}
def db(x):return float(20*np.log10(max(abs(x),1e-12)))
def bounds(q,discard=1):return q['start']['rawByte']//2+48000*discard,min(q['end']['rawByte']//2,len(raw),*(len(v)-960 for v in outputs.values()))
ns,ne=bounds(phases['near-only']);target=near[ns:ne];out=outputs['baseline'][ns:ne]
c=correlate(out,target,method='fft');lags=correlation_lags(len(out),len(target));ok=(lags>=0)&(lags<=960);dsp_lag=int(lags[ok][np.argmax(c[ok])])
ws,we=bounds(phases['far-1-warmup'],4)
c=correlate(raw[ws:we],render,method='fft');lags=correlation_lags(we-ws,len(render))+ws;ok=abs(lags)<144000;lag=int(lags[ok][np.argmax(abs(c[ok]))])
def reference(s,e,offset=lag):return render[s-offset:e-offset]
def spectra(x,y):
 f,xx=welch(x,48000,nperseg=4096,noverlap=2048);_,yy=welch(y,48000,nperseg=4096,noverlap=2048);_,xy=csd(x,y,48000,nperseg=4096,noverlap=2048)
 return f,xx,yy,xy,abs(xy)**2/np.maximum(xx*yy,1e-20)
f,calxx,_,calxy,calcoh=spectra(reference(ws,we),raw[ws:we]);_,npow=welch(target,48000,nperseg=4096,noverlap=2048)
eligible=(f>=300)&(f<=3500)&(calxx>calxx.max()*.001)&(npow<npow.max()*1e-8)
mask=eligible&(calcoh>=.2);calibration_valid=bool(mask.sum()>=8 and mask.sum()/max(eligible.sum(),1)>=.25)
def power(x,y):
 _,xx,_,xy,_=spectra(x,y);return float(np.sum(abs(xy[mask])**2/np.maximum(xx[mask],1e-20)))
negative={}
for k,out in outputs.items():
 length=min(ne-ns,we-ws);negative[k]=power(reference(ws,ws+length),out[ns+dsp_lag:ns+length+dsp_lag])
rows=[]
for name,q in phases.items():
 s,e=bounds(q)
 if e-s<48000:continue
 n=near[s:e];row={'name':name,'rawRmsDbfs':db(np.std(raw[s:e])/32768),'rawClippedSamples':int(np.sum(abs(raw[s:e])>=32700)),'variants':{}}
 for k,out in outputs.items():
  y=out[s+dsp_lag:e+dsp_lag];gain=float(np.dot(y,n)/max(np.dot(n,n),1e-20));corr=float(np.dot(y,n)/max(np.linalg.norm(y)*np.linalg.norm(n),1e-20))
  row['variants'][k]={'nearGainDb':db(gain) if np.any(n) else None,'nearSignedGain':gain if np.any(n) else None,'nearCorrelation':corr if np.any(n) else None}
 if q.get('speakerSignal'):
  x=reference(s,e);raw_power=power(x,raw[s:e]);windows=[]
  for b in range(s,e-48000+1,48000):
   ref_begin=max(0,b-lag-480);ref_end=min(len(render),b+48000-lag+480)
   cr=correlate(raw[b:b+48000],render[ref_begin:ref_end],mode='valid',method='fft');j=int(np.argmax(abs(cr)));local_lag=b-ref_begin-j
   xx=reference(b,b+48000,local_lag)
   if np.std(xx)/32768<1e-3:continue # inactive reference, below -60dBFS
   _,_,_,_,coh=spectra(xx,raw[b:b+48000]);good=eligible&(coh>=.2);coverage=good.sum()/max(eligible.sum(),1)
   level=db(np.std(raw[b:b+48000])/32768);zero=float(np.mean(raw[b:b+48000]==0))
   valid=bool(level>-85 and zero<.95 and good.sum()>=8 and coverage>=.25)
   powers={k:power(xx,out[b+dsp_lag:b+48000+dsp_lag])for k,out in outputs.items()}
   windows.append({'rawLagSamples':local_lag,'rawRmsDbfs':level,'rawZeroFraction':zero,'coverage':float(coverage),'valid':valid,'outputPowers':powers})
  valid_count=sum(w['valid']for w in windows);valid_fraction=valid_count/max(len(windows),1)
  row.update(identifiable=bool(calibration_valid and len(windows)>=3 and valid_fraction>=.75),validWindowFraction=valid_fraction,windows=windows)
  for k,out in outputs.items():
   value=power(x,out[s+dsp_lag:e+dsp_lag]);floor=negative[k]*2 if q.get('digitalNearEnd') else 0
   row['variants'][k].update(coherentEchoReductionDb=db(np.sqrt(raw_power/max(value,floor,1e-20))),outputCoherentPower=value,negativeControlFloor=floor,floorLimited=bool(value<=floor))
 rows.append(row)
by={p['name']:p for p in rows};far=by['far-1'];dt=by['doubletalk'];near_row=by['near-only']
allowed=[k for k in outputs if abs(near_row['variants'][k]['nearGainDb'])<=3 and near_row['variants'][k]['nearSignedGain']>0 and near_row['variants'][k]['nearCorrelation']>=.95]
selected=max(allowed,key=lambda k:far['variants'][k]['coherentEchoReductionDb'])if far['identifiable'] and allowed else None
if a.candidate:
 assert a.candidate in allowed,'Predeclared candidate failed near-only retention'
 selected=a.candidate if far['identifiable'] else None
improvement=normalized=near_difference=None;ci=None
if selected:
 improvement=dt['variants'][selected]['coherentEchoReductionDb']-dt['variants']['baseline']['coherentEchoReductionDb']
 near_difference=dt['variants'][selected]['nearGainDb']-dt['variants']['baseline']['nearGainDb'];normalized=improvement+min(0,near_difference)
 pairs=[]
 for w in dt['windows']:
  if not w['valid']:continue
  base=max(w['outputPowers']['baseline'],negative['baseline']*2);candidate=max(w['outputPowers'][selected],negative[selected]*2)
  pairs.append(db(np.sqrt(base/max(candidate,1e-20)))+min(0,near_difference))
 if pairs:
  rng=np.random.default_rng(20261019);samples=np.array(pairs);boot=rng.choice(samples,(2000,len(samples)),replace=True).mean(axis=1);ci=[float(v)for v in np.quantile(boot,[.025,.975])]
audit_keys=['admInitRecording','admStartRecording','windowsInitRecording','windowsStartRecording','wasapiInitialize','wasapiCaptureService','dmoInitRecording']
recording_safe=all(all(q['endStats']['recordingAudit'][k]==0 for k in audit_keys)for q in r['phases'])
quality=bool(selected and dt['identifiable'] and dt['variants'][selected]['coherentEchoReductionDb']>=6 and dt['variants'][selected]['nearGainDb']>=-6 and near_difference>=-.5 and not any(p['rawClippedSamples']for p in rows) and not r['mixedClippedSamples'] and not r['errors'] and recording_safe)
claim=bool(quality and selected!='baseline' and normalized>=3 and ci and ci[0]>0 and not dt['variants']['baseline']['floorLimited'])
result={'kind':'same-input-windows-doubletalk-comparison','analysisVersion':2,'sampleRate':48000,'dspLatencySamples':dsp_lag,'globalRawRenderLag':lag,'calibrationBins':int(mask.sum()),'eligibleBins':int(eligible.sum()),'calibrationValid':calibration_valid,'selection':('predeclared candidate '+a.candidate+'; DT held out' if a.candidate else 'warmup fixes spectral mask; near-only filters eligibility; far-1 selects; DT held out'),'selected':selected,'doubletalkImprovementOverBaselineDb':improvement,'nearGainDifferenceDb':near_difference,'speechNormalizedImprovementDb':normalized,'pairedWindowBootstrap95CI':ci,'qualityAcceptance':quality,'dspImprovementClaim':claim,'recordingAuditZero':recording_safe,'captureStarts':r['captureStarts'],'videoSource':r['videoSource'],'errors':r['errors'],'phases':rows,'negativeControlCoherentPowers':negative,'report':r,'pcmSha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in a.artifacts.glob('*.pcm')}}
a.output.write_text(json.dumps(result,indent=2,allow_nan=False)+'\n');print(json.dumps({k:result[k]for k in ['selected','calibrationValid','qualityAcceptance','speechNormalizedImprovementDb','pairedWindowBootstrap95CI','dspImprovementClaim']},indent=2))
