#!/usr/bin/env python3
"""Matched raw/clean acoustic and known-near analysis. Never publishes PCM."""
import argparse,hashlib,json
from pathlib import Path
import numpy as np
from scipy.signal import correlate,correlation_lags,welch,csd
p=argparse.ArgumentParser();p.add_argument('trial',type=Path);p.add_argument('output',type=Path);a=p.parse_args();d=a.trial/'artifacts';r=json.loads((d/'report.json').read_text());variants=[name for name in ['baseline','clockDrift','conditioned','headroom'] if (d/(name+'.pcm')).exists()];names=['raw','near','mixed',*variants,'actual_render'];x={n:np.fromfile(d/(n+'.pcm'),'<i2').astype(float) for n in names};ph={q['name']:q for q in r['phases']};raw=x['raw'];reference=x['actual_render']
level=lambda v:float(10*np.log10(max(float(np.mean(v*v))/32768**2,1e-24))) if len(v) else None
def bounds(q,discard=1):return int(q['start']['rawBytes'])//2+int(discard*48000),min(int(q['end']['rawBytes'])//2,len(raw),*(len(x[k])-960 for k in variants))
def db(v):return float(20*np.log10(max(abs(float(v)),1e-12)))
def spectra(ref,v):
 f,xx=welch(ref,48000,nperseg=4096,noverlap=2048);_,yy=welch(v,48000,nperseg=4096,noverlap=2048);_,xy=csd(ref,v,48000,nperseg=4096,noverlap=2048)
 return f,xx,xy,np.abs(xy)**2/np.maximum(xx*yy,1e-20)
ws,we=bounds(ph['far-warmup'],4);v=raw[ws:we];c=correlate(v,reference,method='fft');lags=correlation_lags(len(v),len(reference))+ws;eligible_lags=np.abs(lags)<144000;lag=int(lags[eligible_lags][np.argmax(np.abs(c[eligible_lags]))])
def ref(s,e):
 indices=np.arange(s,e)-lag;out=np.zeros(e-s);valid=(indices>=0)&(indices<len(reference));out[valid]=reference[indices[valid]];return out
f,xx,xy,coh=spectra(ref(ws,we),raw[ws:we]);eligible=(f>=300)&(f<=3500)&(xx>xx.max()*.001);mask=eligible&(coh>=.2);calvalid=bool(mask.sum()>=8 and mask.sum()/max(eligible.sum(),1)>=.25)
latencies={k:432 for k in variants}
if not r['humanNear']:
 s,e=bounds(ph['near-only'])
 for k in variants:
  c=correlate(x[k][s:e],x['near'][s:e],method='fft');l=correlation_lags(e-s,e-s);ok=(l>=0)&(l<=960);latencies[k]=int(l[ok][np.argmax(c[ok])])
rows=[]
for q in r['phases']:
 s,e=bounds(q)
 if e-s<48000:continue
 row={'name':q['name'],'far':q['far'],'nearExpected':q['nearExpected'],'rawRmsDbfs':level(raw[s:e]),'variants':{}}
 for k in variants:
  offset=latencies[k];y=x[k][s+offset:e+offset];row['variants'][k]={'rmsDbfs':level(y),'clipSamples':int(np.sum(np.abs(y)>=32700))}
  if q['nearExpected'] and not r['humanNear']:
   target=x['near'][s:e];gain=float(np.dot(y,target)/max(np.dot(target,target),1e-20));corr=float(np.dot(y,target)/max(np.linalg.norm(y)*np.linalg.norm(target),1e-20));row['variants'][k].update(nearGainDb=db(gain),nearSignedGain=gain,nearCorrelation=corr)
 if q['far']:
  valid_spectra=[];windows=[]
  for start in range(s,e-48000+1,48000):
   vref=ref(start,start+48000);_,px,craw,co=spectra(vref,raw[start:start+48000]);coverage=float(np.sum(eligible&(co>=.2))/max(eligible.sum(),1));valid=bool(level(vref)>-60 and level(raw[start:start+48000])>-85 and coverage>=.25 and np.sum(eligible&(co>=.2))>=8)
   windows.append({'coverage':coverage,'valid':valid})
   if valid:valid_spectra.append((px,craw,{k:spectra(vref,x[k][start+latencies[k]:start+48000+latencies[k]])[2] for k in variants}))
  fraction=sum(w['valid'] for w in windows)/max(len(windows),1);row.update(identifiable=bool(calvalid and len(valid_spectra)>=3 and fraction>=.75),validWindowFraction=fraction,windows=windows)
  if valid_spectra:
   px=np.mean([t[0] for t in valid_spectra],axis=0);den=float(np.sum(np.abs(np.mean([t[1] for t in valid_spectra],axis=0)[mask])**2/np.maximum(px[mask],1e-20)))
   for k in variants:
    power=float(np.sum(np.abs(np.mean([t[2][k] for t in valid_spectra],axis=0)[mask])**2/np.maximum(px[mask],1e-20)));row['variants'][k]['renderCoherentReductionDb']=float(10*np.log10(max(den,1e-24)/max(power,1e-24)))
 rows.append(row)
far=[q for q in rows if q['name'] in ['far-1','far-2']];near=[q for q in rows if q['name'] in ['near-only','near-recovery']];dt=[q for q in rows if q['name'] in ['doubletalk-1','doubletalk-2']]
acceptance={}
for k in variants:
 farpass=bool(len(far)==2 and all(q.get('identifiable') and q['variants'][k].get('renderCoherentReductionDb',-999)>=15 for q in far))
 nearpass=None if r['humanNear'] else all(q['variants'][k]['nearSignedGain']>0 and q['variants'][k]['nearCorrelation']>=.95 and abs(q['variants'][k]['nearGainDb'])<=3 for q in near)
 dtnear=None if r['humanNear'] else all(q['variants'][k]['nearSignedGain']>0 and q['variants'][k]['nearGainDb']>=-6 for q in dt)
 dtecho=bool(len(dt)==2 and all(q.get('identifiable') and q['variants'][k].get('renderCoherentReductionDb',-999)>=6 for q in dt))
 acceptance[k]={'farOnlyPass':farpass,'knownNearOnlyPass':nearpass,'knownDoubleTalkNearPass':dtnear,'doubleTalkEchoIdentifiablePass':dtecho,'humanListeningRequired':r['humanNear']}
result={'kind':'normal-native-render-aec-matched-analysis','humanNear':r['humanNear'],'referenceKind':r.get('finalStats',{}).get('referenceKind','unknown'),'rawRenderLagSamples':lag,'dspLatencySamples':latencies,'calibrationValid':calvalid,'coherentCalibrationBins':int(mask.sum()),'eligibleCalibrationBins':int(eligible.sum()),'phases':rows,'acceptance':acceptance,'rawClippedSamples':int(np.sum(np.abs(raw)>=32700)),'mixedClippedSamples':int(np.sum(np.abs(x['mixed'])>=32700)),'maxAudioGapMs':r['maxAudioGapMs'],'captureStarts':r['captureStarts'],'totals':r['totals'],'stoppedStats':r['stoppedStats'],'errors':r['errors'],'peerSamples':r.get('peer',{}).get('samples'),'pcmSha256':{n:hashlib.sha256((d/(n+'.pcm')).read_bytes()).hexdigest() for n in names},'caveats':['Coherent reduction is not broadband ERLE or source separation.','Real human near has no independent clean reference.','Single setup and short run; camera source is recorded in the application report.']}
a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'calibration':calvalid,'lag':lag,'latencies':latencies,'acceptance':acceptance,'gap':r['maxAudioGapMs'],'errors':r['errors']}))
