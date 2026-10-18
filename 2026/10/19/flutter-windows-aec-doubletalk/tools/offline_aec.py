#!/usr/bin/env python3
"""Replay identical captured PCM through device-free AEC variants.
Raw microphone artifacts never leave ignored build directories.
"""
import argparse,ctypes as C,hashlib,json,pathlib
import numpy as np
from scipy.signal import csd,welch,correlate,correlation_lags
p=argparse.ArgumentParser();p.add_argument('--input',type=pathlib.Path,default=pathlib.Path('build/legacy'));p.add_argument('--lib',type=pathlib.Path,default=pathlib.Path('build/aec/libaec_engine.dylib'));p.add_argument('--out',type=pathlib.Path,default=pathlib.Path('results/offline-legacy.json'));a=p.parse_args()
r=json.loads((a.input/'report.json').read_text());pcm={n:np.fromfile(a.input/(n+'.pcm'),'<i2') for n in ['raw','mixed','near','actual_render','clean']}
lib=C.CDLL(str(a.lib.resolve()));ptr=C.POINTER(C.c_int16)
lib.aec_create_config.argtypes=[C.c_int,C.c_int];lib.aec_create_config.restype=C.c_void_p
lib.aec_reverse.argtypes=[C.c_void_p,ptr,C.c_int];lib.aec_capture.argtypes=[C.c_void_p,ptr,ptr,C.c_int,C.c_int];lib.aec_destroy.argtypes=[C.c_void_p]
def pointer(x):return x.ctypes.data_as(ptr)
def db(x):return float(20*np.log10(max(abs(x),1e-12)))
# Fixed physical reference alignment is estimated on the raw microphone, never
# optimized separately to reward a candidate's cleaned output.
c=correlate(pcm['raw'].astype(float),pcm['actual_render'].astype(float),method='fft');lags=correlation_lags(len(pcm['raw']),len(pcm['actual_render']));ok=abs(lags)<48000*3;lag=int(lags[ok][np.argmax(abs(c[ok]))])
ref=np.zeros(len(pcm['raw']),float);lo=max(0,lag);hi=min(len(ref),len(pcm['actual_render'])+lag);ref[lo:hi]=pcm['actual_render'][lo-lag:hi-lag]
def spectral(x,y):
 f,xx=welch(x,48000,nperseg=4096,noverlap=2048);_,yy=welch(y,48000,nperseg=4096,noverlap=2048);_,xy=csd(x,y,48000,nperseg=4096,noverlap=2048)
 coh=abs(xy)**2/np.maximum(xx*yy,1e-20);return f,xx,yy,xy,coh
rows=[]
cases=[('recorded-live',None,80),('paired-default',0,80),('paired-drift',1,80),('paired-long-filter',2,80),('paired-near-suppression',3,80),('paired-long-drift',4,80),('paired-external-120ms',5,120),('paired-external-160ms',5,160)]
cache=pathlib.Path('build/offline');cache.mkdir(exist_ok=True)
digest=hashlib.sha256(a.lib.read_bytes()+pcm['mixed'].tobytes()+pcm['actual_render'].tobytes()).hexdigest()[:12]
for name,preset,delay in cases:
 if preset is None:out=pcm['clean']
 else:
  path=cache/(name+'-'+digest+'.pcm')
  if path.exists():out=np.fromfile(path,'<i2')
  else:
   h=lib.aec_create_config(1,preset);assert h
   n=len(pcm['mixed'])//480*480;out=np.zeros(n,np.int16);zero=np.zeros(480,np.int16)
   for i in range(0,n,480):
    render=pcm['actual_render'][i:i+480];render=render if len(render)==480 else zero
    assert lib.aec_reverse(h,pointer(render),480)==0
    assert lib.aec_capture(h,pointer(pcm['mixed'][i:i+480]),pointer(out[i:i+480]),480,delay)==0
   lib.aec_destroy(h);out.tofile(path)
 phases=[];near_lag=432
 for phase in r['phases']:
  start=phase['start']['rawByte']//2+48000;end=min(phase['end']['rawByte']//2,len(out)-near_lag)
  if end-start<48000:continue
  raw=pcm['raw'][start:end].astype(float);clean=out[start+near_lag:end+near_lag].astype(float);near=pcm['near'][start:end].astype(float);x=ref[start:end]
  row={'name':phase['name'],'rawRmsDbfs':db(np.std(raw)/32768),'outputRmsDbfs':db(np.std(clean)/32768)}
  near_gain=float(np.dot(clean,near)/max(np.dot(near,near),1e-12)) if np.any(near) else 0
  if np.any(near):row['nearGainDb']=db(near_gain)
  if phase.get('speakerSignal'):
   f,xx,yy,xy,coh=spectral(x,raw);_,_,_,xyout,_=spectral(x,clean)
   bins=(f>=300)&(f<=3500)&(xx>max(xx.max()*.001,1e-12))
   # Exclude independent near harmonics from both raw and cleaned comparisons.
   for hz in [541,1097,1733]:bins &= abs(f-hz)>35
   credible=bins&(coh>=.2)
   power_in=float(np.sum(abs(xy[credible])**2/np.maximum(xx[credible],1e-20)));power_out=float(np.sum(abs(xyout[credible])**2/np.maximum(xx[credible],1e-20)))
   row.update(excitedBins=int(bins.sum()),credibleBins=int(credible.sum()),rawCoherenceMedian=float(np.median(coh[bins])) if np.any(bins) else 0,coherentEchoReductionDb=db(np.sqrt(power_in/max(power_out,1e-20))),identifiable=bool(credible.sum()>=8))
  phases.append(row)
 rows.append({'name':name,'preset':preset,'delayHintMs':delay,'phases':phases})
result={'kind':'same-input-offline-aec-comparison','rawRenderLagSamples':lag,'dspLatencySamples':432,'sourceSha256':{n:hashlib.sha256(pcm[n].tobytes()).hexdigest() for n in pcm},'metric':'Welch cross-spectrum coherent power over 300-3500Hz, raw coherence >=.2, excluding near harmonics; credible bins <8 is inconclusive. Reference aligned once on raw, output latency fixed432.','runs':rows}
a.out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
