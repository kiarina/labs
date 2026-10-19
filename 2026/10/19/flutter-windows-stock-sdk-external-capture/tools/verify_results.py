#!/usr/bin/env python3
"""Verify negative isolation evidence without turning missing audit data into zero."""
import copy,json,pathlib,subprocess,sys,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
def load(name):return json.loads((root/'results'/name).read_text())
control=load('observation-calibration.json');assert control['lostEvents']==control['lostBuffers']==0
assert control['captureInitializeSuccessEvents']==1
record=load('03-record-only.json');source=load('03-source-only.json');positive=load('03-native-mic.json')
for r in (record,source):assert r['sdkCaptureInitializeObserved']==0 and r['uniqueCaptureClientsObserved']==1 and r['additionalCaptureZero']is None
assert source['stockIdentityMatches']
assert positive['stockIdentityMatches'] and positive['sdkCaptureInitializeObserved']==positive['sdkCaptureStartObserved']==1
assert any('mfwmaaec.dll'in c['modules']and c['sdkCallerInStack']for c in positive['captureClients'])
build=load('05-build-identity.json');official=next(s for s in load('official-sdks.json')['sdks']if s['tag']=='libwebrtc.m150.7871.05')
assert build['dllSha256']==official['dllSha256'] and build['prebuiltSdkRecompiled']is False and build['flutterPluginsRebuiltAgainstOfficialHeaders']is True
required=['03-external.json','03-external-playout.json','03-external-volume05.json','03-processing-off.json','03-muted.json','05-external.json']
for name in required:
 r=load(name)
 assert r['stockIdentityMatches'] and r['singleRecordContinuity'],name
 assert r['sdkCaptureInitializeObserved']>=1 and r['sdkCaptureStartObserved']>=1,name
 assert r['uniqueCaptureClientsObserved']>=2 and r['traceLossFree'],name
 assert r['additionalCaptureZero']is False and r['requirementSatisfied']is False,name
 assert r['app']['errors']==[] and r['runtimeSdkInstrumentation']is False,name
 assert not r['app']['sdkIdentity']['customRecordingAuditExportPresent']
 print(name,'SDK capture',r['sdkCaptureInitializeObserved'],r['sdkCaptureStartObserved'],'isolation FAIL (retained evidence)')
assert load('03-processing-off.json')['app']['audioProcessingOff']is True
# Re-evaluate deliberately bad/missing evidence. Neither may establish a solution.
r=load('03-external.json')
with tempfile.TemporaryDirectory()as directory:
 t=pathlib.Path(directory);app=copy.deepcopy(r['app']);obs=copy.deepcopy(r['observation'])
 for mode in ('wrong-sdk','missing-events'):
  aa=copy.deepcopy(app);ee=copy.deepcopy(obs)
  if mode=='wrong-sdk':aa['sdkIdentity']['sha256']='0'*64
  else:ee['events']=[];ee.pop('lostEvents',None);ee.pop('lostBuffers',None)
  (t/'stock_capture_result.json').write_text(json.dumps(aa));(t/'normalized.json').write_text(json.dumps(ee))
  subprocess.run([sys.executable,str(root/'tools/assess_trial.py'),str(t),str(t/'out.json'),'--sdk','libwebrtc.m150.7871.03'],check=True,stdout=subprocess.DEVNULL)
  result=json.loads((t/'out.json').read_text());assert result['requirementSatisfied']is None
  if mode=='missing-events':assert result['additionalCaptureZero']is None
print('Evidence guards PASS. Stock SDK recording-isolation requirement was not achieved.')
