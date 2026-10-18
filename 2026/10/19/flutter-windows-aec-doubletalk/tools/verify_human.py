#!/usr/bin/env python3
"""Check retained physical-human evidence, and ensure bad audit evidence cannot pass."""
import json,pathlib,subprocess,sys,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
def load(name):return json.loads((root/'results'/name).read_text())
r=load('human-trial-1.json');a=load('human-assessment-1.json');h=load('human-listening-1.json');delivery=load('human-delivery-1.json')
assert r['syntheticNearPcmNonzeroSamples']==0 and r['report']['digitalNearPeakBound']==0
assert r['recordingAuditZero'] and r['rawOwnershipPass'] and r['transportPass'] and r['receivedFarPass']
assert r['rawClippedSamples']==r['outputClippedSamples']==r['receiverDroppedToDartMax']==0
assert r['maxAudioGapMs']<100 and r['farOnlyCriterionPass']
assert h['receiverClarityRange'][0]>=4 and h['receiverMissingWords']is False and h['nearRecoveryNormal']
assert a['limitedPracticalAcceptance'] and all(a['checks'].values())
assert delivery['useForPracticalAcceptance']is False
assert all(g['inboundStatsDelta']['packetsLost']==g['inboundStatsDelta']['concealedSamples']==0 for g in delivery['gates'])
with tempfile.TemporaryDirectory()as directory:
 tmp=pathlib.Path(directory);r['recordingAuditZero']=False;(tmp/'metrics.json').write_text(json.dumps(r))
 subprocess.run([sys.executable,str(root/'tools/assess_human.py'),str(tmp/'metrics.json'),str(root/'results/human-listening-1.json'),str(tmp/'assessment.json')],check=True,stdout=subprocess.DEVNULL)
 assert json.loads((tmp/'assessment.json').read_text())['limitedPracticalAcceptance']is False
print('Human evidence/participant assessment and bad-audit rejection PASS (one short setup only).')
