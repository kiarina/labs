#!/usr/bin/env python3
"""Combine stock identity, media flow and independent OS capture evidence."""
import argparse,json,pathlib
p=argparse.ArgumentParser();p.add_argument('trial',type=pathlib.Path);p.add_argument('output',type=pathlib.Path);p.add_argument('--sdk',required=True);a=p.parse_args();root=pathlib.Path(__file__).resolve().parents[1]
r=json.loads((a.trial/'stock_capture_result.json').read_text(encoding='utf-8-sig'));etw=json.loads((a.trial/'normalized.json').read_text(encoding='utf-8-sig'));official=next(s for s in json.loads((root/'results/official-sdks.json').read_text())['sdks']if s['tag']==a.sdk)
identity=r.get('sdkIdentity');stock=None if identity is None else identity.get('sha256')==official['dllSha256'] and identity.get('customRecordingAuditExportPresent')is False and identity.get('customPlayoutExportPresent')is False
clients={}
for e in etw['events']:
 if e['event']!='AudioClientInitialize' or e['data'].get('StreamType')!='1':continue
 data=e['data'];guid=data.get('AudioClientGuidId');modules=sorted({s.get('module','').lower()for s in e.get('stack',[])if s.get('module')})
 clients[guid]={'clientId':guid,'initializeSucceeded':data.get('HResult')=='0x00000000','initializeHresult':data.get('HResult'),'sdkCallerInStack':'libwebrtc.dll'in modules,'modules':modules,'stackAvailable':bool(e.get('stack')),'startSucceeded':False,'endpointSha256':data.get('EndpointIdSha256')}
for e in etw['events']:
 if e['event']!='AudioClientStart':continue
 data=e['data'];guid=data.get('AudioClientGuidId')
 if guid in clients and data.get('HResult')=='0x00000000':clients[guid]['startSucceeded']=True
sdk=[c for c in clients.values()if c['sdkCallerInStack']];sdkinit=sum(c['initializeSucceeded']for c in sdk);sdkstart=sum(c['initializeSucceeded']and c['startSucceeded']for c in sdk)
variant=r['variant'];candidate=variant not in ('record-only','source-only','native-mic');flow=bool(r.get('functionalTransportPass') and all(q.get('rms',0)>1e-6 for q in r['receiver']) and r.get('sourceRms',0)>1e-6)
continuity=bool(r['captureStarts']['record']==1 and all(ph['delta']['rawBytes']>0 and ph['delta']['videoFrames']>0 for ph in r['phases']))if variant!='native-mic'else None
lost=etw.get('lostEvents');buffers=etw.get('lostBuffers');complete=lost==0 and buffers==0
# A positive capture observation disproves zero. Absence alone cannot establish zero.
zero=False if sdkinit or sdkstart else None
result={'kind':'stock-sdk-recording-isolation-trial','sdk':a.sdk,'variant':variant,'stockIdentityMatches':stock,'mediaFlowConfirmed':flow,'audioRtpReceived':all(any(s.get('kind')=='audio' and float(s.get('packetsReceived',0))>0 for s in q.get('inbound',[]))for q in r.get('receiver',[])) if r.get('receiver')else False,'videoDecoded':all(q.get('videoFrames',0)>0 for q in r.get('receiver',[])) if r.get('receiver')else False,'singleRecordContinuity':continuity,'sdkCaptureInitializeObserved':sdkinit,'sdkCaptureStartObserved':sdkstart,'sdkInitializeAttemptsObserved':len(sdk),'uniqueCaptureClientsObserved':len(clients),'lostEvents':lost,'lostBuffers':buffers,'traceLossFree':complete,'additionalCaptureZero':zero,'requirementSatisfied':False if candidate and stock is True and zero is False else None,'reason':'Official SDK identity mismatch; not a valid trial of the requested SDK'if stock is False else 'SDK-owned successful capture client observed'if zero is False else'No SDK capture observed is not sufficient proof of zero; coverage/controls still required','captureClients':list(clients.values()),'runtimeSdkInstrumentation':False,'scope':'Unmodified official DLL; Windows OS ETW observation, not injected counters. Physical camera not established when synthetic.','app':r,'observation':etw}
a.output.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({k:v for k,v in result.items()if k not in ('app','observation','captureClients')}))
