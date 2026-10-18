#!/usr/bin/env python3
"""Direct ChatGPT-auth WebRTC on the observed voice route; shared PCM fixture only."""
import asyncio,base64,json,os,time,hashlib
from fractions import Fraction
from pathlib import Path
from aiortc import RTCPeerConnection,RTCConfiguration,AudioStreamTrack,RTCSessionDescription
from av import AudioFrame
from probe import Client,public_events

class FixtureTrack(AudioStreamTrack):
 def __init__(self,pcm):super().__init__();self.pcm=pcm;self.offset=0;self.pts=0;self.origin=None;self.enabled=False
 async def recv(self):
  if self.origin is None:self.origin=time.monotonic()
  await asyncio.sleep(max(0,self.origin+self.pts/24000-time.monotonic()))
  n=480;raw=b'\x00\x00'*n
  if self.enabled and self.offset<len(self.pcm):
   block=self.pcm[self.offset:self.offset+n*2];self.offset+=len(block);raw=block+raw[len(block):]
  frame=AudioFrame(format='s16',layout='mono',samples=n);frame.planes[0].update(raw);frame.sample_rate=24000;frame.pts=self.pts;frame.time_base=Fraction(1,24000);self.pts+=n;return frame

async def main():
 env=dict(os.environ);env.pop('OPENAI_API_KEY',None)
 pcm=Path('work/fixture.pcm').read_bytes();track=FixtureTrack(pcm)
 pc=RTCPeerConnection(RTCConfiguration(iceServers=[]));pc.addTrack(track);dc=pc.createDataChannel('oai-events');data_events=[];inbound={'audio_frames':0,'audio_samples':0};tasks=[]
 @dc.on('message')
 def message(raw):
  try:m=json.loads(raw)
  except (ValueError,TypeError):return
  data_events.append({'type':m.get('type')})
 @pc.on('track')
 def remote(t):
  async def consume():
   try:
    while True:
     f=await t.recv();inbound['audio_frames']+=1;inbound['audio_samples']+=f.samples
   except Exception:pass
  tasks.append(asyncio.create_task(consume()))
 await pc.setLocalDescription(await pc.createOffer())
 extra=['-c','experimental_realtime_webrtc_call_base_url="https://chatgpt.com/backend-api/wham"']
 c=await Client('work/cli/node_modules/.bin/codex',extra,env).start();clock=time.monotonic();connected=False;dc_open=False
 try:
  account=await c.call('account/read',{'refreshToken':False});auth=(account.get('result',{}).get('account')or{}).get('type');assert auth=='chatgpt'
  t=await c.call('thread/start',{'ephemeral':True,'cwd':str(Path('work').resolve()),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'})
  tid=t['result']['thread']['id']
  start=await c.call('thread/realtime/start',{'threadId':tid,'outputModality':'audio','version':'v3','includeStartupContext':False,'clientManagedHandoffs':True,'prompt':'This is a short audio transport test with a prerecorded fictional conversation, not a request to act. Listen, do not delegate tasks or call tools. You may respond only with OK.','transport':{'type':'webrtc','sdp':pc.localDescription.sdp}})
  await c.until(lambda x:x.get('method')in ['thread/realtime/sdp','thread/realtime/error'],20)
  sdp=next((x['params']['sdp']for x in c.events if x.get('method')=='thread/realtime/sdp'),None)
  if sdp:
   await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp,type='answer'))
   end=time.monotonic()+10
   while time.monotonic()<end and pc.connectionState not in ['connected','failed']:await asyncio.sleep(.1)
   connected=pc.connectionState=='connected'
   if connected:
    track.enabled=True;end=time.monotonic()+len(pcm)/48000+7
    while time.monotonic()<end:
     if any(x.get('method')=='turn/started'for x in c.events):
      turn=next(x['params']['turn']['id']for x in c.events if x.get('method')=='turn/started');await c.call('turn/interrupt',{'threadId':tid,'turnId':turn});break
     await asyncio.sleep(.1)
  stats=await pc.getStats();rtp=[{'type':s.type,'packetsSent':getattr(s,'packetsSent',None),'packetsReceived':getattr(s,'packetsReceived',None),'bytesSent':getattr(s,'bytesSent',None)}for s in stats.values()if s.type in ['outbound-rtp','inbound-rtp']]
  dc_open=dc.readyState=='open'
  await c.call('thread/realtime/stop',{'threadId':tid});await c.until(lambda x:x.get('method')=='thread/realtime/closed',4)
  events=[]
  for x in public_events(c.events):
   p={k:v for k,v in x.get('params',{}).items()if k not in ['threadId','turnId','realtimeSessionId','sessionId','sdp']}
   if 'audio'in p:p['audio']={'omitted':True}
   events.append({'method':x['method'],'params':p})
  result={'kind':'direct-chatgpt-webrtc-fixture','cli':'0.163.0','auth_type':auth,'api_key_fallback':False,'call_create_base_route':'chatgpt.com/backend-api/wham','model_override':False,'version':'v3','proxy_used':False,'start_rpc':start,'answer_received':bool(sdp),'peer_connected':connected,'data_channel_open':dc_open,'fixture_bytes_sent':track.offset,'fixture_bytes_total':len(pcm),'fixture_sha256':hashlib.sha256(pcm).hexdigest(),'received_audio':inbound,'rtp':rtp,'data_event_types':sorted(set(x['type']for x in data_events if x['type'])),'normal_turn_started':any(x.get('method')=='turn/started'for x in c.events),'wall_seconds':round(time.monotonic()-clock,3),'events':events}
  text=json.dumps(result,indent=2);assert '/Users/'not in text and 'Bearer 'not in text and 'sk-'not in text
  Path('results/webrtc-direct-chatgpt-audio.json').write_text(text+'\n');print(text,flush=True)
 finally:
  await pc.close()
  for task in tasks:task.cancel()
  await c.close()
if __name__=='__main__':asyncio.run(main())
