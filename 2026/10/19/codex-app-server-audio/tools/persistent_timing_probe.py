#!/usr/bin/env python3
"""One short synthetic/shared-input probe of actual legacy transcript timing."""
import asyncio,json,os,time
from pathlib import Path
from websockets.asyncio.server import serve
from websockets.asyncio.client import connect
from aiortc import RTCPeerConnection,RTCConfiguration,RTCSessionDescription
from probe import Client
from webrtc_audio import FixtureTrack
from asr_server import STRONG_PROMPT
from delegation_probe import ROOT,BIN

def safe_event(e):
 numbers={};keys=[]
 def visit(value,path=''):
  if isinstance(value,dict):
   for k,v in value.items():keys.append(path+k);visit(v,path+k+'.')
  elif isinstance(value,(int,float))and not isinstance(value,bool):numbers[path[:-1]]=value
  elif isinstance(value,list):
   for v in value[:2]:visit(v,path+'[].')
 visit(e)
 item=e.get('item',{});return {'type':e.get('type'),'keys':sorted(set(keys)),'numbers':numbers,'text':item.get('text',e.get('delta',''))}

async def main():
 env=dict(os.environ);env.pop('OPENAI_API_KEY',None);events=[];start=time.monotonic();client=None
 async def relay(down):
  async with connect('wss://api.openai.com'+down.request.path,additional_headers={k:v for k,v in down.request.headers.raw_items()if k.lower()in ['authorization','chatgpt-account-id','openai-alpha','originator','user-agent','x-session-id','x-codex-turn-metadata','openai-beta']},max_size=32*1024*1024)as up:
   async def forward():
    async for raw in down:await up.send(raw)
   task=asyncio.create_task(forward())
   try:
    async for raw in up:
     e=json.loads(raw);kind=e.get('type','')
     if 'transcript'in kind or kind in ['session.started','turn.done']:
      events.append({'arrival_seconds':round(time.monotonic()-start,3),**safe_event(e)})
     if kind=='delegation.created':continue
     try:await down.send(raw)
     except Exception as error:
      if type(error).__name__.startswith("ConnectionClosed"):break
      raise
   finally:task.cancel()
 pc=RTCPeerConnection(RTCConfiguration(iceServers=[]));pcm=(ROOT/'work/persistent-fixture.pcm').read_bytes();track=FixtureTrack(pcm);pc.addTrack(track);pc.createDataChannel('oai-events')
 @pc.on('track')
 def remote(t):
  async def consume():
   try:
    while True:await t.recv()
   except Exception:pass
  asyncio.create_task(consume())
 try:
  await pc.setLocalDescription(await pc.createOffer())
  async with serve(relay,'127.0.0.1',0,max_size=32*1024*1024)as server:
   port=server.sockets[0].getsockname()[1];client=await Client(BIN,['-c','experimental_realtime_webrtc_call_base_url="https://chatgpt.com/backend-api/wham"','-c',f'experimental_realtime_ws_base_url="http://127.0.0.1:{port}/v1"'],env).start()
   a=await client.call('account/read',{'refreshToken':False});assert a['result']['account']['type']=='chatgpt'
   t=await client.call('thread/start',{'ephemeral':True,'cwd':str(ROOT/'work'),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'});tid=t['result']['thread']['id']
   await client.call('thread/realtime/start',{'threadId':tid,'version':'v3','outputModality':'audio','includeStartupContext':False,'clientManagedHandoffs':True,'prompt':STRONG_PROMPT,'transport':{'type':'webrtc','sdp':pc.localDescription.sdp}})
   assert await client.until(lambda e:e.get('method')=='thread/realtime/sdp',25)
   sdp=next(e['params']['sdp']for e in client.events if e.get('method')=='thread/realtime/sdp');await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp,type='answer'))
   until=time.monotonic()+10
   while pc.connectionState!='connected'and time.monotonic()<until:await asyncio.sleep(.05)
   assert pc.connectionState=='connected';enabled=time.monotonic()-start;track.enabled=True
   await asyncio.sleep(len(pcm)/48000+5)
   await client.call('thread/realtime/stop',{'threadId':tid})
   r={'auth':'chatgpt','api_key_fallback':False,'connections':1,'physical_microphone_used':False,'fixture_enabled_at_seconds':round(enabled,3),'fixture_sent_bytes':track.offset,'fixture_total_bytes':len(pcm),'events':events};data=json.dumps(r,ensure_ascii=False,indent=2);assert '/Users/'not in data and 'Bearer 'not in data
   (ROOT/'results/persistent-timing-probe.json').write_text(data+'\n');print(json.dumps({'transcripts':len([e for e in events if 'transcript'in e['type']]),'numeric_fields':sorted({k for e in events if 'transcript'in e['type']for k in e['numbers']}),'keys':sorted({k for e in events if 'transcript'in e['type']for k in e['keys']})}),flush=True)
 finally:
  await pc.close()
  if client:await client.close()
if __name__=='__main__':asyncio.run(main())
