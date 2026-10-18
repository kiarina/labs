#!/usr/bin/env python3
"""Two live ChatGPT WebRTC sessions, alternating shared SCD segments."""
import asyncio,base64,hashlib,json,os,time
from array import array
from fractions import Fraction
from pathlib import Path
from aiortc import RTCPeerConnection,RTCConfiguration,RTCSessionDescription,AudioStreamTrack
from av import AudioFrame
from websockets.asyncio.server import serve
from websockets.asyncio.client import connect
from probe import Client
from asr_server import STRONG_PROMPT
from delegation_probe import ROOT,BIN

class RoutedTrack(AudioStreamTrack):
 def __init__(self,owner,pcm,segments):
  super().__init__();self.owner=owner;self.pcm=pcm;self.segments=segments;self.pts=0;self.origin=None;self.source_origin=None;self.sent={};self.scheduling_late_ms=0
 async def recv(self):
  if self.origin is None:self.origin=time.monotonic()
  target=self.origin+self.pts/24000
  await asyncio.sleep(max(0,target-time.monotonic()));self.scheduling_late_ms=max(self.scheduling_late_ms,(time.monotonic()-target)*1000)
  n=480;raw=bytearray(n*2)
  if self.source_origin is not None:
   a=round((target-self.source_origin)*24000);b=a+n
   for seg in self.segments:
    if seg['connection']!=self.owner:continue
    if seg.get('play_start') is None and 'play_start'in seg:continue
    play=round(seg.get('play_start',seg['start'])*24000);stop=play+seg['end_sample']-seg['start_sample']
    lo=max(a,play);hi=min(b,stop)
    if hi>lo:
     raw[(lo-a)*2:(hi-a)*2]=self.pcm[(lo-play+seg['start_sample'])*2:(hi-play+seg['start_sample'])*2];sid=seg['id'];now=time.monotonic()-self.source_origin
     stat=self.sent.setdefault(sid,{'first_send':round(now,4),'last_send':0,'samples':0});stat['last_send']=round(now,4);stat['samples']+=hi-lo
  frame=AudioFrame(format='s16',layout='mono',samples=n);frame.planes[0].update(bytes(raw));frame.sample_rate=24000;frame.pts=self.pts;frame.time_base=Fraction(1,24000);self.pts+=n;return frame

class Lane:
 def __init__(self,name,pcm,segments,clock):
  self.name=name;self.clock=clock;self.events=[];self.kinds={};self.errors=[];self.output_nonzero=0;self.track=RoutedTrack(name,pcm,segments);self.pc=RTCPeerConnection(RTCConfiguration(iceServers=[]));self.pc.addTrack(self.track);self.pc.createDataChannel('oai-events');self.client=None;self.tasks=[];self.states=[]
  @self.pc.on('connectionstatechange')
  def state():self.states.append({'at':round(time.monotonic()-self.clock,4),'state':self.pc.connectionState})
  @self.pc.on('track')
  def remote(t):
   async def consume():
    try:
     while True:await t.recv()
    except Exception:pass
   self.tasks.append(asyncio.create_task(consume()))
 async def relay(self,down):
  async with connect('wss://api.openai.com'+down.request.path,additional_headers={k:v for k,v in down.request.headers.raw_items()if k.lower()in ['authorization','chatgpt-account-id','openai-alpha','originator','user-agent','x-session-id','x-codex-turn-metadata','openai-beta']},max_size=32*1024*1024)as up:
   async def forward():
    async for raw in down:await up.send(raw)
   task=asyncio.create_task(forward())
   try:
    async for raw in up:
     e=json.loads(raw);kind=e.get('type','');self.kinds[kind]=self.kinds.get(kind,0)+1
     if kind=='session.output_audio.delta':
      samples=array('h');samples.frombytes(base64.b64decode(e.get('audio',e.get('delta',''))));self.output_nonzero+=sum(v!=0 for v in samples)
     if 'transcript'in kind:
      self.events.append({'at':round(time.monotonic()-self.clock,4),'type':kind,'text':e.get('item',{}).get('text',e.get('delta','')),'start_ms':e.get('start_ms'),'end_ms':e.get('end_ms')})
     if kind=='error':self.errors.append({k:v for k,v in e.get('error',{}).items()if k in ['type','code','message','param']});continue
     if kind in ['delegation.created','session.delegation.created']:continue
     try:await down.send(raw)
     except Exception:break
   finally:task.cancel()
 async def start(self):
  self.server=await serve(self.relay,'127.0.0.1',0,max_size=32*1024*1024);port=self.server.sockets[0].getsockname()[1]
  env=dict(os.environ);env.pop('OPENAI_API_KEY',None)
  self.client=await Client(BIN,['-c','experimental_realtime_webrtc_call_base_url="https://chatgpt.com/backend-api/wham"','-c',f'experimental_realtime_ws_base_url="http://127.0.0.1:{port}/v1"'],env).start()
  a=await self.client.call('account/read',{'refreshToken':False});assert a['result']['account']['type']=='chatgpt'
  t=await self.client.call('thread/start',{'ephemeral':True,'cwd':str(ROOT/'work'),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'});self.tid=t['result']['thread']['id']
  await self.pc.setLocalDescription(await self.pc.createOffer())
  await self.client.call('thread/realtime/start',{'threadId':self.tid,'version':'v3','outputModality':'audio','includeStartupContext':False,'clientManagedHandoffs':True,'prompt':STRONG_PROMPT,'transport':{'type':'webrtc','sdp':self.pc.localDescription.sdp}})
  assert await self.client.until(lambda e:e.get('method')=='thread/realtime/sdp',25),'no SDP'
  sdp=next(e['params']['sdp']for e in self.client.events if e.get('method')=='thread/realtime/sdp');await self.pc.setRemoteDescription(RTCSessionDescription(sdp=sdp,type='answer'))
  deadline=time.monotonic()+10
  while self.pc.connectionState!='connected'and time.monotonic()<deadline:await asyncio.sleep(.02)
  assert self.pc.connectionState=='connected','peer failed'
  print(f'{self.name} connected',flush=True)
 async def close(self):
  if self.client:
   try:await self.client.call('thread/realtime/stop',{'threadId':self.tid})
   except Exception:pass
  await self.pc.close()
  for task in self.tasks:task.cancel()
  if self.client:await self.client.close()
  if hasattr(self,'server'):self.server.close();await self.server.wait_closed()
 def result(self,origin):
  return {'connection':self.name,'events':[{**e,'source_arrival':round(e['at']-origin,4)}for e in self.events],'event_counts':self.kinds,'errors':self.errors,'output_nonzero_samples':self.output_nonzero,'sent_segments':self.track.sent,'max_scheduling_late_ms':round(self.track.scheduling_late_ms,3),'states':self.states,'normal_turns':sum(e.get('method')=='turn/started'for e in self.client.events)}

async def main():
 mode=os.environ.get('TWO_MODE','natural');pcm=(ROOT/'work/persistent-fixture.pcm').read_bytes();refs=json.loads((ROOT/'asr/app/assets/refine-reference.json').read_text())
 segments=[{'id':f'segment-{i+1}','connection':'AB'[i%2],'speaker':r['speaker'],'start':r['start'],'end':r['end'],'start_sample':round(r['start']*24000),'end_sample':round(r['end']*24000)}for i,r in enumerate(refs)]
 if mode in ['rapid','guarded']:
  # A deliberate short-turn stress: retain only the opening 450/500 ms of two
  # intervening B utterances. No time stretching; clipped speech is a limitation.
  original=pcm;chunks=[];cursor=0
  for i,seg in enumerate(segments):
   lo=seg['start_sample'];hi=seg['end_sample']
   if i in [1,3]:hi=min(hi,lo+round((.45 if i==1 else .5)*24000))
   chunk=original[lo*2:hi*2];seg['original_start']=seg['start'];seg['original_end']=hi/24000
   seg['start_sample']=cursor;seg['end_sample']=cursor+len(chunk)//2;seg['start']=cursor/24000;seg['end']=seg['end_sample']/24000;cursor=seg['end_sample'];chunks.append(chunk)
  pcm=b''.join(chunks)
 if mode=='guarded':
  for seg in segments:seg['play_start']=None
 clock=time.monotonic();lanes=[Lane(name,pcm,segments,clock)for name in 'AB'];status='error';failure=None;origin=0
 try:
  await asyncio.gather(*(l.start()for l in lanes))
  # Give both RTP clocks 200 ms before a shared source timeline begins.
  source=time.monotonic()+.2;origin=source-clock
  for lane in lanes:lane.track.source_origin=source
  print('both peers connected; playing shared fixture',flush=True)
  if mode=='guarded':
   last_end={};global_end=0
   for seg in segments:
    lane=lanes['AB'.index(seg['connection'])]
    while True:
     now=time.monotonic()-source
     old_end=last_end.get(lane.name)
     last=max((e['at']-origin for e in lane.events if e['type']=='input_transcript.added'),default=-1e6)
     target=max(seg['start'],global_end,(old_end+1 if old_end is not None else 0),(last+1 if old_end is not None else 0))
     if now>=target:break
     await asyncio.sleep(.01)
    # Schedule 40 ms ahead so both 20 ms RTP clocks can emit the first sample.
    seg['play_start']=round((time.monotonic()-source+.04)*24000)/24000
    seg['queue_wait_ms']=round((seg['play_start']-seg['start'])*1000,1)
    global_end=seg['play_start']+seg['end']-seg['start'];last_end[lane.name]=global_end
   await asyncio.sleep(max(0,global_end-(time.monotonic()-source))+6)
  else:await asyncio.sleep(origin-(time.monotonic()-clock)+len(pcm)/48000+6)
  status='complete'
 except Exception as error:failure=type(error).__name__+': '+str(error)
 finally:
  rows=[l.result(origin)for l in lanes if l.client]
  await asyncio.gather(*(l.close()for l in lanes),return_exceptions=True)
  r={'status':status,'failure':failure,'mode':mode,'auth':'chatgpt','api_key_fallback':False,'cli':'0.163.0','model_override':False,'physical_microphone_used':False,'source_origin':round(origin,4),'fixture_seconds':len(pcm)/48000,'fixture_sha256':hashlib.sha256(pcm).hexdigest(),'segments':segments,'lanes':rows,'scope':'shared fixture and retained SCD boundaries; no live VAD/SCD cost; no prototype'}
  data=json.dumps(r,ensure_ascii=False,indent=2);assert '/Users/'not in data and 'Bearer 'not in data
  (ROOT/f'results/two-connections-{mode}.json').write_text(data+'\n');print(json.dumps({'status':status,'failure':failure,'lanes':[{k:l[k]for k in ['connection','event_counts','errors','output_nonzero_samples']}for l in rows]},ensure_ascii=False),flush=True)
 if failure:raise RuntimeError('two connection test failed; see retained result')
if __name__=='__main__':asyncio.run(main())
