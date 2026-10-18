#!/usr/bin/env python3
"""Compare decoded real-voice PCM with already-AEC-cleaned sender PCM, not clean near."""
import argparse,json,pathlib
import numpy as np
from scipy.signal import correlate, butter, sosfilt
p=argparse.ArgumentParser();p.add_argument('artifacts',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);a=p.parse_args();d=a.artifacts;r=json.loads((d/'report.json').read_text());base=np.fromfile(d/'baseline.pcm','<i2').astype(float);received=np.fromfile(d/'human_received.pcm','<i2').astype(float);rows=[]
for phase in r['transportPhases']:
 if 'receiver'not in phase:continue
 q=phase['receiver'];y=received[q['pcmStartByte']//2:q['pcmEndByte']//2];trim=14400;y=y[trim:-4800];n=len(y)
 # Full raw-output timeline handles gate idle intervals; normalized alignment avoids loud-click bias.
 c=correlate(base,y,mode='valid',method='fft');sums=np.r_[0,np.cumsum(base*base)];energy=sums[n:]-sums[:-n];corr=c/np.sqrt(np.maximum(energy*np.dot(y,y),1e-20));lag=int(np.argmax(corr));v=base[lag:lag+n];gain=float(np.dot(v,y)/max(np.dot(v,v),1e-20));windows=[]
 for b in range(0,n-960+1,960):
  t=v[b:b+960];u=y[b:b+960];trms=np.sqrt(np.mean(t*t));urms=np.sqrt(np.mean(u*u))
  if trms>100:windows.append({'sourceRms':float(trms),'receiverRms':float(urms),'energyLossOver20dB':bool(urms<trms*.1)})
 longest=run=0
 for w in windows:run=run+1 if w['energyLossOver20dB']else 0;longest=max(longest,run)
 band=butter(4,[300,3500],btype='bandpass',fs=48000,output='sos');bv=sosfilt(band,base);by=sosfilt(band,y);blocks=[]
 for start in range(0,n-48000+1,48000):
  target=by[start:start+48000];center=lag+start;lo=max(0,center-1920);hi=min(len(bv),center+48000+1920);source=bv[lo:hi]
  cc=correlate(source,target,mode='valid',method='fft');squares=np.r_[0,np.cumsum(source*source)];energy=squares[48000:]-squares[:-48000];normalized=cc/np.sqrt(np.maximum(energy*np.dot(target,target),1e-20));shift=int(np.argmax(normalized));matched=source[shift:shift+48000]
  if np.sqrt(np.mean(matched*matched))>100:blocks.append({'startSeconds':start/48000,'localDelayDifferenceSamples':lo+shift-center,'bandCorrelation':float(normalized[shift]),'rmsRatioDb':float(20*np.log10(max(np.linalg.norm(target)/max(np.linalg.norm(matched),1e-12),1e-12)))})
 before=next((q for q in phase['inboundBefore']if q.get('kind')=='audio'),{});after=next(q for q in phase['inboundAfter']if q.get('kind')=='audio');stats={key:float(after.get(key,0))-float(before.get(key,0))for key in ('packetsLost','concealedSamples','concealmentEvents','insertedSamplesForDeceleration','removedSamplesForAcceleration')}
 rows.append({'inboundStatsDelta':stats,'bandLimitedOneSecondDiagnostics':blocks,'wholeWindowRmsRatioDb':float(20*np.log10(np.linalg.norm(y)/max(np.linalg.norm(v),1e-12))),'gate':phase['name'],'sourceAlignmentSample':lag,'receiverTrimSamples':trim,'comparedSamples':n,'correlation':float(corr[lag]),'signedTransferGain':gain,'transferGainDb':float(20*np.log10(max(abs(gain),1e-12))),'active20msWindows':len(windows),'receiverEnergyLossOver20dBWindows':sum(w['energyLossOver20dB']for w in windows),'longestConsecutiveActiveWindowLossMs':longest*20,'meaning':'Opus/transport transfer relative to AEC output; does not establish AEC near preservation.'})
result={'kind':'physical-human-decoded-delivery','gates':rows,'simpleWaveformMatchPass':all(t['correlation']>=.8 and abs(t['transferGainDb'])<=3 and t['longestConsecutiveActiveWindowLossMs']<60 for t in rows),'useForPracticalAcceptance':False,'limitation':'Receiver RTP stats record inserted/removed samples for adaptive time scaling, so fixed global sample alignment is inappropriate. This explains why waveform identity is not an acceptance criterion, without claiming all residual distortion is explained. Exploratory global waveform correlation/projection gain are sensitive to codec phase and adaptive jitter delay; projection gain is not volume attenuation. Band-limited blocks search +/-40ms diagnostically, not as a new acceptance threshold. Full-timeline waveform match can match repeated phrases; it is delivery consistency evidence, not absolute clock/word-boundary accuracy.'};a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
