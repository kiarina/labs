#!/usr/bin/env python3
"""Bound native zero-fill increments between public stats snapshots; no PCM published."""
import argparse,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('report',type=Path);p.add_argument('output',type=Path);a=p.parse_args();r=json.loads(a.report.read_text());chunks=r['chunkTimeline'];rows=[]
for q in r['phases']:
 mark=next(t for t in r['timeline'] if t['stage']==q['name']);start=mark['clockUs'];duration=(q['end']['rawBytes']-q['start']['rawBytes'])/96000
 lo=start+1000000;hi=start+int((duration-.25)*1000000)
 events=[]
 for prev,cur in zip(chunks,chunks[1:]):
  n=cur['native']['captureUnderflows']-prev['native']['captureUnderflows']
  if n>0 and prev['processedUs']>=lo and cur['processedUs']<=hi:events.append({'relativeMs':round((cur['processedUs']-start)/1000,2),'zeroFillBlocks':n,'snapshotIntervalMs':round((cur['processedUs']-prev['processedUs'])/1000,2)})
 b=q['bridgeStatsStart']['native'];e=q['bridgeStats']['native']
 rows.append({'phase':q['name'],'sending':q['end']['injectedAudioBytes'] > q['start']['injectedAudioBytes'],'underflowDelta':e['captureUnderflows']-b['captureUnderflows'],'flushBytesDelta':e['captureFlushedBytes']-b['captureFlushedBytes'],'interiorUnderflowBlocks':sum(x['zeroFillBlocks'] for x in events),'interiorEvents':events})
n=r['bridgeStatsBeforeClose']['native'];submitted=r['bridgeStatsBeforeClose']['audioFramesSubmitted']*960
accounted=(n['audioBlocks']-n['captureUnderflows'])*960+n['captureFlushedBytes']+n['captureQueuedBytes']+n['captureDroppedBytes']
out={'errors':r['errors'],'captureStarts':r['captureStarts'],'cameraUniqueSampledFrames':r['cameraUniqueSampledFrames'],'maxAudioGapMs':r['maxAudioGapMs'],'phases':rows,'native':n,'submittedBytes':submitted,'accountedBytes':accounted,'accountingExact':submitted==accounted,'notes':['Snapshots bound zero-fill timing to record callback intervals, not exact sample timestamps.','Interior excludes first1s and last250ms of each approximate capture-duration phase.','Off phases intentionally stop source injection; underflow there is not audible speech loss.']};a.output.write_text(json.dumps(out,indent=2)+'\n')
