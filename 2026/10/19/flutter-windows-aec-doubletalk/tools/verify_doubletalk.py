#!/usr/bin/env python3
"""Verify retained evidence and guard claims; a failed experiment is valid evidence."""
import json,pathlib
root=pathlib.Path(__file__).resolve().parents[1]
def load(name):return json.loads((root/'results'/name).read_text())
for name in ('digital-baseline.json','digital-linear.json','digital-long-refined.json'):
 assert load(name)['pass'],name
near=load('offline-speech-near.json')
assert near['mixedClippedSamples']==0
assert near['dspLatencyByVariant']['baseline']==near['dspLatencyByVariant']['linear80']
assert near['retentionEligibility']['linear80']
assert not near['retentionEligibility']['strict80']
dt=next(x for x in near['phases']if x['name']=='doubletalk')['variants']
assert dt['linear80']['active100msGainMinimumDb']>dt['baseline']['active100msGainMinimumDb']
assert dt['linear80']['longestActiveWindowRunBelowMinus6DbMs']==0
for path in sorted((root/'results').glob('trial-*.json')):
 r=json.loads(path.read_text())
 if r.get('analysisVersion')!=4:continue
 assert r['captureStarts']['microphone']==1,path.name
 assert r['recordingAuditZero'],path.name
 assert r['errors']==[],path.name
 if r['dspImprovementClaim']:
  assert r['qualityAcceptance'] and r['speechNormalizedImprovementDb']>=3,path.name
  assert r['pairedWindowBootstrap95CI'][0]>0,path.name
 print(path.name, 'quality=',r['qualityAcceptance'],'improvement=',r['dspImprovementClaim'])
assert load('trial-3.json')['dspImprovementClaim'] is False
assert load('trial-4.json')['dspImprovementClaim'] is False
final=load('trial-6.json')
assert final['qualityAcceptance'] and not final['dspImprovementClaim']
audit=final['report']['captureStoppedStats']['recordRawAudit']
assert audit['rawRequests']==audit['rawPropertiesAccepted']==audit['rawStarts']==1
assert audit['mfCreateRequests']==audit['activeRawCaptures']==audit['lastHresult']==0
assert audit['nativeCaptureFrames']>0
assert final['measuredActualRenderPeak']==18000
print('Evidence and claim guards PASS; this does not turn failed trials into an AEC success.')
