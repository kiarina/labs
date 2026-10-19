#!/usr/bin/env python3
"""Paired headroom acceptance with expected0.5 level accounted for explicitly."""
import argparse,json,hashlib
from pathlib import Path
import numpy as np
p=argparse.ArgumentParser();p.add_argument('trial',type=Path);p.add_argument('analysis',type=Path);p.add_argument('received',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
r=json.loads((a.trial/'artifacts/report.json').read_text());m=json.loads(a.analysis.read_text());expected=.5;offset_db=float(20*np.log10(expected));names=['baseline','headroom'];pcm={n:np.fromfile(a.trial/'artifacts'/(n+'.pcm'),'<i2')for n in names};received=np.fromfile(a.received,'<i2')
full=lambda x:int(np.sum((x==32767)|(x==-32768)))
far=[];near=[];dt=[];waveform=[]
for q in m['phases']:
 b=q['variants']['baseline'];h=q['variants']['headroom'];row={'phase':q['name']}
 if q['nearExpected']:
  phase=next(v for v in r['phases'] if v['name']==q['name']);start=phase['start']['rawBytes']//2+48000;end=min(phase['end']['rawBytes']//2-24000,len(pcm['baseline'])-960,len(pcm['headroom'])-960);lb=m['dspLatencySamples']['baseline'];lh=m['dspLatencySamples']['headroom'];x=pcm['baseline'][start+lb:end+lb].astype(float);y=pcm['headroom'][start+lh:end+lh].astype(float)/expected
  if len(x) and len(x)==len(y):waveform.append({'phase':q['name'],'normalizedOutputCorrelation':float(np.dot(x,y)/max(np.linalg.norm(x)*np.linalg.norm(y),1e-20)),'normalizedRmsDifferenceDb':float(10*np.log10(max(np.dot(y,y),1e-20)/max(np.dot(x,x),1e-20))),'meaning':'Complete output waveform similarity, not isolated near speech.'})
 if q['name'] in ['far-1','far-2']:
  row.update(identifiable=q.get('identifiable',False),baselineReductionDb=b.get('renderCoherentReductionDb'),headroomReductionDb=h.get('renderCoherentReductionDb'))
  if row['headroomReductionDb'] is not None and row['baselineReductionDb'] is not None:
   row['headroomLevelNormalizedReductionDb']=row['headroomReductionDb']+offset_db;row['pairedNormalizedDifferenceDb']=row['headroomLevelNormalizedReductionDb']-row['baselineReductionDb']
  far.append(row)
 if not r['humanNear'] and q['name'] in ['near-only','near-recovery','doubletalk-1','doubletalk-2']:
  row.update(baselineGainDb=b['nearGainDb'],headroomActualGainDb=h['nearGainDb'],headroomGainRelativeToExpectedDb=h['nearGainDb']-offset_db,baselineCorrelation=b['nearCorrelation'],headroomCorrelation=h['nearCorrelation']);row['pairedRelativeGainDifferenceDb']=row['headroomGainRelativeToExpectedDb']-row['baselineGainDb'];(near if not q['far'] else dt).append(row)
exact={n:full(x)for n,x in pcm.items()};exact['decodedReceiver']=full(received)
farpass=bool(len(far)==2 and all(q.get('identifiable')and q.get('headroomLevelNormalizedReductionDb',-999)>=15 and q.get('pairedNormalizedDifferenceDb',-999)>=-1 for q in far))
nearpass=None if r['humanNear'] else bool(len(near)==2 and all(q['headroomCorrelation']>=.95 and abs(q['headroomGainRelativeToExpectedDb'])<=3 and q['pairedRelativeGainDifferenceDb']>=-.5 for q in near))
dtpass=None if r['humanNear'] else bool(len(dt)==2 and all(q['headroomGainRelativeToExpectedDb']>=-6 and q['pairedRelativeGainDifferenceDb']>=-.5 for q in dt))
result={'kind':'paired-live-headroom','session':r['session'],'sentProfile':r.get('selectedOutput'),'captureGain':expected,'postGain':1,'normalizationOnlyInAnalysis':True,'exactFullScaleSamples':exact,'farOnly':far,'nearOnly':near,'doubletalkKnownNear':dt,'pairedCompleteWaveform':waveform,'acceptance':{'zeroOutputAndReceiverFullScale':exact['headroom']==exact['decodedReceiver']==0,'farNonRegression':farpass,'knownNear':nearpass,'knownDtNear':dtpass,'humanListeningRequired':r['humanNear']},'decodedSamples':len(received),'decodedSha256':hashlib.sha256(a.received.read_bytes()).hexdigest(),'maxCaptureGapMs':r['maxAudioGapMs'],'caveats':['Far transfer normalized for0.5 gain; actual output was not amplified.','Human total raw RMS ratios do not isolate near speech.','No physical Windows camera or broader hardware/OS claim.']}
a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
