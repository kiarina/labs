#!/usr/bin/env python3
"""Validate retained evidence; synthetic-device runs are never acoustic proof."""
import json,math,pathlib
root=pathlib.Path(__file__).resolve().parents[1]
for name in ('macos-digital.json','windows-digital.json','web-digital.json','web-browser-digital.json'):
 r=json.loads((root/'results'/name).read_text());r=r.get('result',r)
 assert r['farOnly']['erleDb']>=15,name
 assert r['nearOnly']['correlation']>=.95,name
 assert abs(20*math.log10(abs(r['nearOnly']['gain'])))<=3,name
 assert 20*math.log10(abs(r['doubleTalk']['gain']))>=-6,name
 assert r['doubleTalk']['echoImprovementDb']>=6,name
 assert r['pass'],name
 print(name,'PASS digital acceptance')
for name in ('macos-acoustic.json','ios-acoustic.json','android-acoustic-trace.json','web-acoustic-analysis.json'):
 r=json.loads((root/'results'/name).read_text());r=r.get('result',r)
 assert not r['errors'],name
 assert len(r['phases'])==8,name
 assert r['captureStarts']=={'camera':1,'microphone':1},name
 assert r['mixedClippedSamples']==0,name
 for phase in r['phases']:
  assert phase['end']['video']-phase['start']['video']>=phase['seconds']*5,name
  assert phase['end']['rawByte']-phase['start']['rawByte']>=phase['seconds']*48000*2*.7,name
 rows=r['analysis']['phases']
 assert sum(p.get('correlatedEchoReductionDb',0)>6 for p in rows if p['name'] in ('far-1','far-2'))==2,name
 assert all(p['nearGainDb']>=-6 for p in rows if 'nearGainDb' in p),name
 print(name,'PASS retained physical echo/near evidence (not human speech)')

# Windows physical DT quality is deliberately not called a pass. Verify the
# transport/recording-isolation evidence without hiding its weak acoustics.
r=json.loads((root/'results/windows-acoustic.json').read_text())
assert not r['errors']
assert r['captureStarts']['microphone']==1 and r['captureStarts']['camera']==0
assert r['transport']['pass']
for phase in r['phases']:
 audit=phase['endStats']['recordingAudit']
 for key in ('admInitRecording','admStartRecording','windowsInitRecording','windowsStartRecording','dmoInitRecording','wasapiInitialize','wasapiCaptureService'):
  assert audit[key]==0,key
print('windows-acoustic.json PASS transport/recording isolation; physical DT quality remains insufficient')
r=json.loads((root/'results/web-flutter-rtc-real-probe.json').read_text())['result']
assert r['pass'] and r['gateStarts']==2 and not r['cleanMicPlayedToSpeaker']
assert r['farDecodedEnergy']>0 and r['cleanDecodedEnergy']>0
for phase in r['gatePhases']:
 if not phase['transmitting']:assert phase['injectedBytes']==0 and phase['receivedRtpBytes']==0
print('web-flutter-rtc-real-probe.json PASS decoded playout and clean send gates')

for name in ('macos-rtc-integrated.json', 'ios-rtc-integrated.json'):
 r=json.loads((root/'results'/name).read_text())
 assert not r['errors'] and r['transport']['pass'],name
 assert r['remoteFarPhase']['pass'],name
 assert r['remoteFarPhase']['microphoneInjected'] is False,name
 assert r['remoteFarPhase']['receivedSamples']>0,name
 assert r['captureStarts']=={'camera':1,'microphone':1},name
 print(name,'PASS camera/record lifetime, decoded far playout and clean gates')
