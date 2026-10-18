#!/usr/bin/env python3
"""Same real far/mic/reference plus known capture-only speech-like near.
No new microphone or playback. This tests DSP retention, not physical human DT.
"""
import argparse,array,ctypes as C,hashlib,json,pathlib
import numpy as np
from scipy.signal import correlate,correlation_lags
root=pathlib.Path(__file__).resolve().parents[1]
parser=argparse.ArgumentParser();parser.add_argument('--artifacts',type=pathlib.Path,default=root/'build/trial-2');parser.add_argument('--output',type=pathlib.Path,default=root/'results/offline-speech-near.json');args=parser.parse_args();art=args.artifacts;r=json.loads((art/'report.json').read_text())
raw=np.fromfile(art/'raw.pcm','<i2');render=np.fromfile(art/'actual_render.pcm','<i2');speech=np.fromfile(root/'app/assets/far_speech.pcm','<i2')
index=(np.arange(len(raw))*.93+len(speech)//2).astype(np.int64)%len(speech);near=(speech[index].astype(float)*(6000/9000)).round().astype(np.int16);active=np.zeros(len(raw),bool)
for p in r['phases']:
 if p.get('digitalNearEnd'):active[p['start']['rawByte']//2:p['end']['rawByte']//2]=True
near[~active]=0;mixed=raw.astype(np.int32)+near.astype(np.int32);clips=int(np.sum(abs(mixed)>32767));assert clips==0;mixed=mixed.astype(np.int16)
lib=C.CDLL(str(root/'build/aec/libaec_engine.dylib'));ptr=C.POINTER(C.c_int16);lib.aec_create_config.argtypes=[C.c_int,C.c_int];lib.aec_create_config.restype=C.c_void_p;lib.aec_reverse.argtypes=[C.c_void_p,ptr,C.c_int];lib.aec_capture.argtypes=[C.c_void_p,ptr,ptr,C.c_int,C.c_int];lib.aec_destroy.argtypes=[C.c_void_p]
def pt(x):return x.ctypes.data_as(ptr)
def db(x):return float(20*np.log10(max(abs(x),1e-12)))
outputs={};n=len(mixed)//480*480
for name,preset,delay in [(n,p,80)for n,p in [('baseline',0),('external80',5),('strict80',7),('gentle80',8),('transparent80',9),('refined80',10),('gentleRefined80',11),('linear80',12)]]+[('longRefined100',14,100),('longRefined120',14,120)]:
 h=lib.aec_create_config(1,preset);assert h;out=np.zeros(n,np.int16);zero=np.zeros(480,np.int16)
 for i in range(0,n,480):
  ref=render[i:i+480];ref=ref if len(ref)==480 else zero
  assert lib.aec_reverse(h,pt(ref),480)==0;assert lib.aec_capture(h,pt(mixed[i:i+480]),pt(out[i:i+480]),480,delay)==0
 lib.aec_destroy(h);outputs[name]=out
p=next(p for p in r['phases']if p['name']=='near-only');s=p['start']['rawByte']//2+48000;e=p['end']['rawByte']//2-960
lags_by_variant={}
for key,out in outputs.items():
 c=correlate(out[s:e].astype(float),near[s:e].astype(float),method='fft');lags=correlation_lags(e-s,e-s);ok=(lags>=0)&(lags<=960);lags_by_variant[key]=int(lags[ok][np.argmax(c[ok])])
lag=lags_by_variant['baseline'];rows=[]
for p in r['phases']:
 if not p.get('digitalNearEnd'):continue
 s=p['start']['rawByte']//2+48000;e=min(p['end']['rawByte']//2,n-lag);target=near[s:e].astype(float);variants={}
 for name,out in outputs.items():
  offset=lags_by_variant[name];y=out[s+offset:e+offset].astype(float);gain=float(np.dot(y,target)/max(np.dot(target,target),1e-20));corr=float(np.dot(y,target)/max(np.linalg.norm(y)*np.linalg.norm(target),1e-20));error=y-gain*target
  gains=[]
  for b in range(0,len(target)-4800+1,4800):
   t=target[b:b+4800];v=y[b:b+4800]
   if np.std(t)>30:gains.append(db(np.dot(v,t)/max(np.dot(t,t),1e-20)))
  longest=run=0
  for g in gains:
   run=run+1 if g < -6 else 0;longest=max(longest,run)
  variants[name]={'active100msGainMinimumDb':min(gains),'active100msGain1stPercentileDb':float(np.quantile(gains,.01)),'longestActiveWindowRunBelowMinus6DbMs':longest*100,'gainDb':db(gain),'signedGain':gain,'correlation':corr,'projectionSnrDb':db(np.linalg.norm(gain*target)/max(np.linalg.norm(error),1e-20)),'active100msGain10thPercentileDb':float(np.quantile(gains,.1))}
 rows.append({'name':p['name'],'variants':variants})
base=[x['variants']['baseline']for x in rows];strict=[x['variants']['strict80']for x in rows]
passed=all(t['signedGain']>0 and t['correlation']>=.95 and t['correlation']>=b['correlation']-.02 and t['gainDb']>=b['gainDb']-.5 and t['active100msGain10thPercentileDb']>=b['active100msGain10thPercentileDb']-1 for b,t in zip(base,strict))
eligibility={k:all(t['variants'][k]['signedGain']>0 and t['variants'][k]['correlation']>=.95 and t['variants'][k]['correlation']>=t['variants']['baseline']['correlation']-.02 and t['variants'][k]['gainDb']>=t['variants']['baseline']['gainDb']-.5 and t['variants'][k]['active100msGain10thPercentileDb']>=t['variants']['baseline']['active100msGain10thPercentileDb']-1 for t in rows) for k in outputs}
result={'kind':'offline-real-far-known-speech-near-retention','nearConstruction':'shared speech at0.93rate, half-file shifted, peak6000, capture-only near phases; not a physical near microphone','dspLatencySamples':lag,'dspLatencyByVariant':lags_by_variant,'mixedClippedSamples':clips,'rawSha256':hashlib.sha256(raw.tobytes()).hexdigest(),'nearSha256':hashlib.sha256(near.tobytes()).hexdigest(),'phases':rows,'strictRetentionPass':passed,'retentionEligibility':eligibility}
args.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
