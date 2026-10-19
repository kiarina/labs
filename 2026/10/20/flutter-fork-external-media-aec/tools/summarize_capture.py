#!/usr/bin/env python3
"""Publish counters/gate interiors, never camera pixels or capture device IDs."""
import argparse,json
from pathlib import Path
import numpy as np
p=argparse.ArgumentParser();p.add_argument('trial',type=Path);p.add_argument('received',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
r=json.loads((a.trial/'artifacts/report.json').read_text());pcm=np.fromfile(a.received,'<i2').astype(float);rows=[]
for q in r['phases']:
 start=q['start'];end=q['end'];row={'phase':q['name'],'rawBytesDelta':end['rawBytes']-start['rawBytes'],'processedBytesDelta':end['cleanBytes']-start['cleanBytes'],'cameraFramesDelta':end['cameraFrames']-start['cameraFrames'],'cameraSourceFramesDelta':end.get('cameraSourceFrames',end['cameraFrames'])-start.get('cameraSourceFrames',start['cameraFrames']),'injectedAudioBytesDelta':end['injectedAudioBytes']-start['injectedAudioBytes'],'injectedVideoFramesDelta':end['injectedVideoFrames']-start['injectedVideoFrames'],'peerSamplesDelta':q['peerEnd']['samples']-q['peerStart']['samples'],'peerVideoFramesDelta':q['peerEnd']['videoFrames']-q['peerStart']['videoFrames']}
 if row['injectedAudioBytesDelta']==0:
  s=q['peerStart']['samples']+24000;e=min(q['peerEnd']['samples']-12000,len(pcm));v=pcm[s:e]
  row['gateInteriorSamples']=len(v);row['gateInteriorRmsDbfs']=float(10*np.log10(max(float(np.mean(v*v))/32768**2,1e-24))) if len(v) else None
 rows.append(row)
gated=[q for q in rows if q['phase']=='doubletalk-gate-off'];resume=[q for q in rows if q['phase']=='doubletalk-2']
out={'captureStarts':r['captureStarts'],'cameraSource':'physical camera plugin image stream; Windows Pixel Fold via OS virtual-camera transport when selected','cameraUniqueSampledFrames':r.get('cameraUniqueSampledFrames'),'bridgeStatsBeforeClose':r.get('bridgeStatsBeforeClose'),'captureAndDspContinueDuringDoubletalkGate':bool(gated and all(q['rawBytesDelta']>0 and q['processedBytesDelta']>0 and q['cameraSourceFramesDelta']>0 and q['injectedAudioBytesDelta']==q['injectedVideoFramesDelta']==0 for q in gated)),'receiveResumesAfterGate':bool(resume and all(q['injectedAudioBytesDelta']>0 and q['injectedVideoFramesDelta']>0 and q['peerSamplesDelta']>0 and q['peerVideoFramesDelta']>0 for q in resume)),'phases':rows,'micCheck':r.get('micCheck'),'maxAudioCallbackGapMs':r['maxAudioGapMs'],'errors':r['errors'],'caveats':['Start counts and increasing counters distinguish continuous acquisition from callback timing; they do not prove long-duration clock synchronization.','Already-submitted RTP/decoder buffers cannot be retracted when a gate closes.','Queue drops, intentionally flushed data and inactive-source drops are separate counters.']}
a.output.write_text(json.dumps(out,indent=2)+'\n');print(json.dumps({k:out[k] for k in ['captureStarts','captureAndDspContinueDuringDoubletalkGate','receiveResumesAfterGate','errors']}))
