#!/usr/bin/env python3
"""Physical human trial diagnostics. No synthetic clean-near gain assertion."""
import argparse,hashlib,json,pathlib,wave
import numpy as np
from scipy.signal import correlate,correlation_lags,welch,csd
p=argparse.ArgumentParser();p.add_argument('artifacts',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);a=p.parse_args();d=a.artifacts
r=json.loads((d/'report.json').read_text());assert r['kind']=='physical-human-doubletalk' and r['syntheticNearInjection'] is False
names=['raw','baseline','candidate80','linear80','longRefined100','longRefined120','actual_render']
def read(name):
 f=d/(name+'.pcm')
 if not f.exists():f=d/('aec_'+name+'.pcm')
 return np.fromfile(f,'<i2').astype(float)
x={n:read(n)for n in names};raw=x['raw'];render=x['actual_render'];variants=names[1:-1];ph={q['name']:q for q in r['phases']}
def bounds(q,discard=1):return q['start']['rawByte']//2+48000*discard,min(q['end']['rawByte']//2,len(raw),*(len(x[n])-960 for n in variants))
def dbpower(v):return float(10*np.log10(max(float(v),1e-24)))
def level(v):return dbpower(np.mean(v*v)/32768**2)
ws,we=bounds(ph['far-1-warmup'],4);v=raw[ws:we];c=correlate(v,render,method='fft');lags=correlation_lags(len(v),len(render))+ws;ok=abs(lags)<144000;lag=int(lags[ok][np.argmax(abs(c[ok]))])
# Same pinned filterbank has ~432sample latency; human voice supplies no independent clean target.
latency=432

def reference(s,e):
 indices=np.arange(s,e)-lag;out=np.zeros(e-s);valid=(indices>=0)&(indices<len(render));out[valid]=render[indices[valid]];return out

def spectra(ref,y):
 f,xx=welch(ref,48000,nperseg=4096,noverlap=2048);_,yy=welch(y,48000,nperseg=4096,noverlap=2048);_,xy=csd(ref,y,48000,nperseg=4096,noverlap=2048)
 return f,xx,xy,abs(xy)**2/np.maximum(xx*yy,1e-20)
f,xx,xy,coh=spectra(reference(ws,we),raw[ws:we]);eligible=(f>=300)&(f<=3500)&(xx>xx.max()*.001);mask=eligible&(coh>=.2);calvalid=bool(mask.sum()>=8 and mask.sum()/max(eligible.sum(),1)>=.25)
rows=[]
for q in r['phases']:
 s,e=bounds(q)
 if e-s<48000:continue
 row={'name':q['name'],'physicalHumanNearExpected':q.get('physicalHumanNearExpected',False),'rawRmsDbfs':level(raw[s:e]),'variants':{n:{'rmsDbfs':level(x[n][s+latency:e+latency]),'clipSamples':int(np.sum(abs(x[n][s+latency:e+latency])>=32700))}for n in variants}}
 if q['speakerSignal'] and q['name']!='rtc-far-playback':
  windows=[];spect=[]
  for start in range(s,e-48000+1,48000):
   ref=reference(start,start+48000);_,px,craw,co=spectra(ref,raw[start:start+48000]);coverage=float(np.sum(eligible&(co>=.2))/max(eligible.sum(),1));valid=bool(level(ref)>-60 and level(raw[start:start+48000])>-85 and coverage>=.25 and np.sum(eligible&(co>=.2))>=8)
   windows.append({'coverage':coverage,'valid':valid,'rawRmsDbfs':level(raw[start:start+48000])})
   if valid:spect.append((px,craw,{n:spectra(ref,x[n][start+latency:start+48000+latency])[2]for n in variants}))
  fraction=sum(w['valid']for w in windows)/max(len(windows),1);row['identifiable']=bool(calvalid and len(spect)>=3 and fraction>=.75);row['validWindowFraction']=fraction;row['windows']=windows
  if spect:
   px=np.mean([t[0]for t in spect],axis=0);den=float(np.sum(abs(np.mean([t[1]for t in spect],axis=0)[mask])**2/np.maximum(px[mask],1e-20)))
   for n in variants:
    power=float(np.sum(abs(np.mean([t[2][n]for t in spect],axis=0)[mask])**2/np.maximum(px[mask],1e-20)))
    row['variants'][n]['renderCoherentReductionDb']=dbpower(den/max(power,1e-24))
   row['metricCaveat']='DT real-near cross spectral leakage/distortion is not bounded; not source-separated echo or clean-near retention.'
 rows.append(row)
keys=['admInitRecording','admStartRecording','windowsInitRecording','windowsStartRecording','wasapiInitialize','wasapiCaptureService','dmoInitRecording'];stats=r['captureStoppedStats'];audit=stats.get('recordingAudit',{});ra=stats.get('recordRawAudit',{})
auditok=all(audit.get(k)==0 for k in keys) and audit.get('peerConnections',0)>0 and audit.get('peerConnections')==audit.get('suppressedPeerConnections')
rawok=ra.get('rawRequests')==ra.get('rawPropertiesAccepted')==ra.get('rawStarts')==1 and ra.get('mfCreateRequests')==ra.get('activeRawCaptures')==ra.get('lastHresult')==0 and ra.get('nativeCaptureFrames',0)>0
# Local listening files only. All share the same gain, preserving relative echo/near levels.
clips={}
for phase in ('near-only','doubletalk','near-recovery'):
 q=ph[phase];s=q['start']['rawByte']//2;e=q['end']['rawByte']//2
 for n in ('raw','baseline','longRefined120'):clips[phase+'-'+n]=x[n][s+(0 if n=='raw' else latency):e+(0 if n=='raw'else latency)]
received=np.fromfile(d/'human_received.pcm','<i2').astype(float)
formats={(c.get('sampleRate'),c.get('channels'))for c in r['receiverChunks']};assert formats=={(48000,1)},formats
for phase in r['transportPhases']:
 if 'receiver'in phase:
  v=phase['receiver'];clips['receiver-'+phase['name']]=received[v['pcmStartByte']//2:v['pcmEndByte']//2]
peak=max(float(np.max(abs(v)))for v in clips.values()if len(v));gain=min(4.,.90*32767/max(peak,1));out=d/'listening';out.mkdir(exist_ok=True)
for name,v in clips.items():
 with wave.open(str(out/(name+'.wav')),'wb')as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(48000);w.writeframes(np.round(np.clip(v*gain,-32768,32767)).astype('<i2').tobytes())
far=[t for t in rows if t['name']in ('far-1','far-2')];farpass=all(t.get('identifiable') and t['variants']['baseline'].get('renderCoherentReductionDb',-999)>=15 for t in far)
result={'kind':'physical-human-doubletalk-diagnostics','sampleRate':48000,'outputLatencyAssumptionSamples':latency,'rawRenderLagSamples':lag,'calibrationBins':int(mask.sum()),'eligibleBins':int(eligible.sum()),'calibrationValid':calvalid,'phases':rows,'syntheticNearPcmNonzeroSamples':int(np.count_nonzero(read('near'))),'outputClippedSamples':sum(v['clipSamples'] for q in rows for v in q['variants'].values()),'receivedFarPass':ph['rtc-far-playback']['receivedFar']['pass'],'receiverDroppedToDartMax':max(c.get('droppedToDart') or 0 for c in r['receiverChunks']),'rawClippedSamples':int(np.sum(abs(raw)>=32700)),'recordingAuditZero':auditok,'rawOwnershipPass':rawok,'transportPass':r['transport']['pass'],'aborted':r['participantAborted'],'farOnlyCriterionPass':farpass,'maxAudioGapMs':r['maxAudioGapMs'],'maxVideoGapMs':r['maxVideoGapMs'],'captureStarts':r['captureStarts'],'videoSource':r['videoSource'],'errors':r['errors'],'receiverFormat':{'sampleRate':48000,'channels':1},'receiverSamples':len(received),'listeningCommonGain':gain,'humanListeningAssessment':'separate participant assessment; see human-assessment-1.json','practicalAcceptance':None,'practicalAcceptanceNote':'Diagnostics alone cannot establish practicality; run assess_human.py with the participant listening record.','pcmSha256':{n:hashlib.sha256((d/(n+'.pcm')if(d/(n+'.pcm')).exists()else d/('aec_'+n+'.pcm')).read_bytes()).hexdigest()for n in names},'report':r}
a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:result[k]for k in ('recordingAuditZero','rawOwnershipPass','transportPass','farOnlyCriterionPass','maxAudioGapMs','receiverSamples','listeningCommonGain')}))
