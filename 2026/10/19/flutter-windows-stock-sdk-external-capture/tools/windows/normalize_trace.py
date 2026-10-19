#!/usr/bin/env python3
"""Normalize xperf CSV + ETL-reader stacks without private endpoint/path data."""
import argparse,csv,hashlib,json,pathlib,re,datetime
p=argparse.ArgumentParser();p.add_argument('csv',type=pathlib.Path);p.add_argument('stacks',type=pathlib.Path);p.add_argument('pid',type=int);p.add_argument('output',type=pathlib.Path);a=p.parse_args()
headers={};modules=[];events=[]
for line in a.csv.open(errors='replace'):
 try:row=[x.strip()for x in next(csv.reader([line],skipinitialspace=True))]
 except csv.Error:continue
 if len(row)<2:continue
 kind=row[0]
 if row[1]=='TimeStamp':headers[kind]=row[1:];continue
 if len(row)<4 or not re.search(r'\('+str(a.pid)+r'\)$',row[2]):continue
 if kind in ['I-Start','I-DCStart']:
  try:modules.append((int(row[3],16),int(row[4],16),pathlib.PureWindowsPath(row[8]).name))
  except (ValueError,IndexError):pass
 if kind.startswith('Microsoft.Windows.Audio.Client/'):
  name=kind.split('/')[1]
  if name not in ['AudioClientInitialize','IAudioClient::Initialize','IAudioClient::GetService','IAudioClient::Start','AudioClientStart','AudioClientStop']:continue
  data=dict(zip(headers.get(kind,[]),row[1:]));safe={}
  for k,v in data.items():
   if k in ['EndpointId','EndpointInstanceId']:
    safe[k+'Sha256']=hashlib.sha256(v.encode()).hexdigest()
   elif k not in ['etw:UserSid','etw:SessionId']:safe[k]=v
  events.append({'event':name,'data':safe})
stacks=[json.loads(line)for line in a.stacks.open(encoding="utf-8-sig")]
byname={}
for s in stacks:
 if s['pid']==a.pid and s['provider']=='Microsoft.Windows.Audio.Client':byname.setdefault(s['event'],[]).append(s)
used={}
for e in events:
 name=e['event'];i=used.get(name,0);used[name]=i+1;ss=byname.get(name,[])
 if i>=len(ss):e['stackMissing']=True;continue
 s=ss[i];out=[]
 for raw in s['stack']:
  address=int(raw,16);m=next((m for m in modules if m[0]<=address<m[1]),None)
  out.append({'module':m[2],'rva':hex(address-m[0])}if m else{'unresolvedAddress':raw})
 e.update(pid=s['pid'],tid=s['tid'],qpc=s['qpc'],stack=out)
init=[e for e in events if e['event']=='AudioClientInitialize']
capture=[e for e in init if e['data'].get('StreamType')=='1']
stats_path=a.csv.parent/'trace-stats.txt'
def lost(kind):
 if not stats_path.exists():return None
 raw=stats_path.read_bytes();text=raw.decode('utf-16' if raw.startswith(b'\xff\xfe') else 'utf-8-sig',errors='replace')
 m=re.search(r'Total\s*#\s*Lost\s+'+kind+r'\s*:\s*(\d+)',text,re.I)
 return int(m.group(1)) if m else None
traceStartUtc=None
if stats_path.exists():
 raw=stats_path.read_bytes();text=raw.decode('utf-16' if raw.startswith(b'\xff\xfe') else 'utf-8-sig',errors='replace')
 m=re.search(r'Start time \(UTC\)\s*:\s*(\d{4})/(\d{2})/(\d{2}):(\d{2}):(\d{2}):(\d{2})\.(\d+)',text)
 if m:traceStartUtc=datetime.datetime(*map(int,m.groups()[:6]),int(m[7][:6]),tzinfo=datetime.timezone.utc)
for e in events:
 try:e['utc']=(traceStartUtc+datetime.timedelta(microseconds=float(e['data']['TimeStamp']))).isoformat() if traceStartUtc else None
 except (KeyError,ValueError):e['utc']=None
started=[]
for e in capture:
 guid=e['data'].get('AudioClientGuidId')
 starts=[x for x in events if x['event']=='AudioClientStart' and x['data'].get('AudioClientGuidId')==guid and x['data'].get('HResult')=='0x00000000']
 if e['data'].get('HResult')=='0x00000000' and starts:started.append({'audioClientGuidId':guid,'initialize':e,'start':starts[0]})
def sdk_stack(e):return any(f.get('module','').lower()=='libwebrtc.dll' for f in e.get('stack',[]))
result={'schemaVersion':1,'pid':a.pid,'captureInitializeEvents':len(capture),
 'captureInitializeSuccessEvents':sum(e['data'].get('HResult')=='0x00000000'for e in capture),
 'captureInitializeWithStack':sum(bool(e.get('stack'))for e in capture),
 'captureStartedClients':started,'renderInitializeEvents':[e for e in init if e['data'].get('StreamType')=='0'],'sdkCaptureInitializeSuccessEvents':sum(sdk_stack(e) and e['data'].get('HResult')=='0x00000000' for e in capture),'sdkCaptureStartedClients':sum(sdk_stack(x['initialize']) or sdk_stack(x['start']) for x in started),'lostEvents':lost('Events'),'lostBuffers':lost('Buffers'),'events':events,'limitations':['Capture initialization and streaming are separate; creation of an AEC DMO alone is not capture.','Missing events/stacks or unvalidated DMO paths cannot prove zero additional capture.','Provider events sharing AudioClientGuidId are lifecycle views, not separate streams.'],
 'inputSha256':{x.name:hashlib.sha256(x.read_bytes()).hexdigest()for x in [a.csv,a.stacks]}}
a.output.write_text(json.dumps(result,indent=2)+'\n')
print(json.dumps({k:v for k,v in result.items()if not isinstance(v,(list,dict))}))
