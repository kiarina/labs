#!/usr/bin/env python3
"""Same-input spectral echo and known-near transfer comparison.
Selection uses far-1 only. DT is held out. Never exports microphone PCM.
"""
import argparse,json,pathlib,hashlib
import numpy as np
from scipy.signal import correlate,correlation_lags,welch,csd
p=argparse.ArgumentParser();p.add_argument('artifacts',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);a=p.parse_args()
def load(n):
 path=a.artifacts/(n+'.pcm')
 if not path.exists():path=a.artifacts/('aec_'+n+'.pcm')
 return np.fromfile(path,'<i2').astype(float)
rpath=a.artifacts/'report.json'
if not rpath.exists():rpath=a.artifacts/'aec_result.json'
r=json.loads(rpath.read_text());raw=load('raw');near=load('near');render=load('actual_render')
outputs={n:load(n) for n in ['baseline','candidate80','candidate100','candidate120','candidate160','long80','long100'] if (a.artifacts/(n+'.pcm')).exists() or (a.artifacts/('aec_'+n+'.pcm')).exists()}
assert 'baseline' in outputs and len(outputs)>=4
def db(x):return float(20*np.log10(max(abs(x),1e-12)))
warm=next(p for p in r['phases'] if p['name']=='far-1-warmup');begin=warm['start']['rawByte']//2+48000*4;end=warm['end']['rawByte']//2
c=correlate(raw[begin:end],render,method='fft');lags=correlation_lags(end-begin,len(render))+begin;valid=abs(lags)<48000*3;lag=int(lags[valid][np.argmax(abs(c[valid]))])
# Each 1 s raw window refines this shared raw-only lag within +/-10ms.
# This tracks drift without separately rewarding a cleaned candidate's alignment.
rows=[]
for phase in r['phases']:
 name=phase['name'];start=phase['start']['rawByte']//2+48000;stop=min(phase['end']['rawByte']//2,len(raw),*(len(v)-432 for v in outputs.values()))
 if stop-start<48000:continue
 n=near[start:stop];row={'name':name,'seconds':(stop-start)/48000,'rawRmsDbfs':db(np.std(raw[start:stop])/32768),'rawClippedSamples':int(np.sum(abs(raw[start:stop])>=32700)),'variants':{}}
 for k,y in outputs.items():
  yy=y[start+432:stop+432];gain=float(np.dot(yy,n)/max(np.dot(n,n),1e-20))
  row['variants'][k]={'outputRmsDbfs':db(np.std(yy)/32768),'nearGainDb':db(gain) if np.any(n) else None}
 if phase.get('speakerSignal'):
  totals={k:0.0 for k in outputs};power_raw=0.0;credible_count=excited_count=0;windows=[]
  for s in range(start,stop-48000+1,48000):
   y=raw[s:s+48000];ref_begin=max(0,s-lag-480);ref_end=min(len(render),s+48000-lag+480)
   if ref_end-ref_begin<48000:continue
   cr=correlate(y,render[ref_begin:ref_end],mode='valid',method='fft');j=int(np.argmax(abs(cr)));local_lag=s-(ref_begin+j);x=render[s-local_lag:s+48000-local_lag]
   f,xx=welch(x,48000,nperseg=1024,noverlap=512);_,yy=welch(y,48000,nperseg=1024,noverlap=512);_,xy=csd(x,y,48000,nperseg=1024,noverlap=512)
   coh=abs(xy)**2/np.maximum(xx*yy,1e-20);bins=(f>=300)&(f<=3500)&(xx>max(xx.max()*.001,1e-12))
   for hz in [541,1097,1733]:bins &= abs(f-hz)>70
   if not np.any(bins):continue
   good=bins&(coh>=.2);credible_count+=int(good.sum());excited_count+=int(bins.sum())
   power_raw+=float(np.sum(abs(xy[good])**2/np.maximum(xx[good],1e-20)))
   for k,out in outputs.items():
    _,cross=csd(x,out[s+432:s+48000+432],48000,nperseg=1024,noverlap=512)
    totals[k]+=float(np.sum(abs(cross[good])**2/np.maximum(xx[good],1e-20)))
   windows.append({'rawLagSamples':local_lag,'rawCoherenceMedian':float(np.median(coh[bins])),'excitedBins':int(bins.sum()),'credibleBins':int(good.sum())})
  coverage=credible_count/max(excited_count,1);identifiable=bool(len(windows)>=3 and credible_count/len(windows)>=8 and coverage>=.25)
  row.update(identifiable=identifiable,rawCoherentCoverage=coverage,windows=windows)
  for k,power in totals.items():row['variants'][k]['coherentEchoReductionDb']=db(np.sqrt(power_raw/max(power,1e-20)))
 rows.append(row)
far=next(x for x in rows if x['name']=='far-1');dt=next(x for x in rows if x['name']=='doubletalk');near_only=next(x for x in rows if x['name']=='near-only')
eligible=[k for k in outputs if abs(near_only['variants'][k]['nearGainDb'])<=3]
selected=max(eligible,key=lambda k:far['variants'][k]['coherentEchoReductionDb']) if far['identifiable'] and eligible else None
improvement=dt['variants'][selected]['coherentEchoReductionDb']-dt['variants']['baseline']['coherentEchoReductionDb'] if selected else None
quality=bool(selected and dt['identifiable'] and dt['variants'][selected]['coherentEchoReductionDb']>=6 and dt['variants'][selected]['nearGainDb']>=-6 and not any(p['rawClippedSamples'] for p in rows) and r['mixedClippedSamples']==0)
audit_keys=['admInitRecording','admStartRecording','windowsInitRecording','windowsStartRecording','wasapiInitialize','wasapiCaptureService','dmoInitRecording']
recording_safe=all(all(p['endStats']['recordingAudit'][k]==0 for k in audit_keys) for p in r['phases'])
quality=quality and recording_safe and not r['errors'] and r['captureStarts']['microphone']==1
result={'kind':'same-input-windows-doubletalk-comparison','sampleRate':48000,'dspLatencySamples':432,'globalRawRenderLag':lag,'selection':'far-1 only after near-only retention filter; DT held out','selected':selected,'doubletalkImprovementOverBaselineDb':improvement,'qualityAcceptance':quality,'dspImprovementClaim':bool(quality and selected!='baseline' and improvement>=3),'recordingAuditZero':recording_safe,'captureStarts':r['captureStarts'],'videoSource':r['videoSource'],'errors':r['errors'],'captureGapsMs':{'audio':r['maxAudioGapMs'],'video':r['maxVideoGapMs']},'phases':rows,'report':r,'pcmSha256':{p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in a.artifacts.glob('*.pcm')}}
a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:result[k] for k in ['selected','doubletalkImprovementOverBaselineDb','qualityAcceptance','dspImprovementClaim']},indent=2))
