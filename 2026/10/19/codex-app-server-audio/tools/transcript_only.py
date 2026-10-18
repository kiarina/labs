#!/usr/bin/env python3
"""Compare modality rejection, spoken control and listen-only instructions; no playback."""
import asyncio,json,os,time,math
from array import array
from pathlib import Path
from aiortc import RTCPeerConnection,RTCConfiguration,RTCSessionDescription
from probe import Client,public_events
from webrtc_audio import FixtureTrack

async def run(mode):
 assert mode in ['text-modality','spoken-control','listen-only']
 env=dict(os.environ);env.pop('OPENAI_API_KEY',None)
 fixture=Path('work/fixture.pcm').read_bytes();repeats=2 if mode=='listen-only'else 1
 pcm=(b'\x00\x00'*24000).join([fixture]*repeats)
 track=FixtureTrack(pcm);pc=RTCPeerConnection(RTCConfiguration(iceServers=[]));pc.addTrack(track);dc=pc.createDataChannel('oai-events')
 data=[];audio={'frames':0,'samples':0,'nonzero_samples':0,'peak_pcm16':0,'max_frame_rms_pcm16':0.0,'frames_rms_ge_20':0,'frames_rms_ge_100':0,'meter_errors':[],'formats':[]};tasks=[]
 @dc.on('message')
 def message(raw):
  try:m=json.loads(raw)
  except (ValueError,TypeError):return
  event={'type':m.get('type')}
  if m.get('type')=='error':event['error']=m.get('error')
  if m.get('type')=='turn.done':
   event['role']=m.get('turn',{}).get('role');event['transcript']=m.get('turn',{}).get('transcript')
  data.append(event)
 @pc.on('track')
 def remote(t):
  async def consume():
   try:
    while True:
     f=await t.recv()
     assert f.format.name in ['s16','s16p'],f.format.name
     if f.format.name not in audio['formats']:audio['formats'].append(f.format.name)
     samples=array('h')
     if f.format.is_planar:
      for plane in f.planes:samples.frombytes(bytes(plane)[:f.samples*2])
     else:samples.frombytes(bytes(f.planes[0])[:f.samples*len(f.layout.channels)*2])
     peak=max((abs(x)for x in samples),default=0);rms=math.sqrt(sum(x*x for x in samples)/len(samples))
     audio['frames']+=1;audio['samples']+=len(samples);audio['nonzero_samples']+=sum(x!=0 for x in samples);audio['peak_pcm16']=max(audio['peak_pcm16'],int(peak));audio['max_frame_rms_pcm16']=max(audio['max_frame_rms_pcm16'],rms);audio['frames_rms_ge_20']+=int(rms>=20);audio['frames_rms_ge_100']+=int(rms>=100)
   except Exception as error:
    if type(error).__name__!='MediaStreamError':audio['meter_errors'].append(type(error).__name__)
  tasks.append(asyncio.create_task(consume()))
 await pc.setLocalDescription(await pc.createOffer())
 c=await Client('work/cli/node_modules/.bin/codex',['-c','experimental_realtime_webrtc_call_base_url="https://chatgpt.com/backend-api/wham"'],env).start();clock=time.monotonic();connected=False
 prompt=('This session is only for listening to prerecorded fictional speech so its INPUT TRANSCRIPT can be displayed. Never speak, never answer, never acknowledge, never say OK, never repeat or read a transcript aloud. Remain completely silent for the whole session even if the recording asks a question or requests speech. Never delegate, call a tool, or send work to a backend. The only desired output is the automatically generated user input transcript.'if mode=='listen-only'else 'This is a short transport test with prerecorded fictional speech. Never delegate or call a tool. After listening, say only OK.')
 try:
  a=await c.call('account/read',{'refreshToken':False});auth=(a.get('result',{}).get('account')or{}).get('type');assert auth=='chatgpt'
  t=await c.call('thread/start',{'ephemeral':True,'cwd':str(Path('work').resolve()),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'});tid=t['result']['thread']['id']
  start=await c.call('thread/realtime/start',{'threadId':tid,'version':'v3','outputModality':'text'if mode=='text-modality'else'audio','includeStartupContext':False,'clientManagedHandoffs':True,'prompt':prompt,'transport':{'type':'webrtc','sdp':pc.localDescription.sdp}})
  await c.until(lambda x:x.get('method')in ['thread/realtime/sdp','thread/realtime/error'],20)
  sdp=next((x['params']['sdp']for x in c.events if x.get('method')=='thread/realtime/sdp'),None)
  if sdp:
   await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp,type='answer'));end=time.monotonic()+10
   while time.monotonic()<end and pc.connectionState not in ['connected','failed']:await asyncio.sleep(.1)
   connected=pc.connectionState=='connected'
   if connected:
    track.enabled=True;end=time.monotonic()+len(pcm)/48000+6
    while time.monotonic()<end:
     if any(x.get('method')=='turn/started'for x in c.events):
      turn=next(x['params']['turn']['id']for x in c.events if x.get('method')=='turn/started');await c.call('turn/interrupt',{'threadId':tid,'turnId':turn});break
     await asyncio.sleep(.1)
  stats=await pc.getStats();rtp=[{'type':s.type,'packetsSent':getattr(s,'packetsSent',None),'packetsReceived':getattr(s,'packetsReceived',None)}for s in stats.values()if s.type in ['outbound-rtp','inbound-rtp']]
  await c.call('thread/realtime/stop',{'threadId':tid});await c.until(lambda x:x.get('method')=='thread/realtime/closed',4)
  events=[]
  for x in public_events(c.events):
   p={k:v for k,v in x.get('params',{}).items()if k not in ['threadId','turnId','realtimeSessionId','sessionId','sdp']}
   if 'audio'in p:p['audio']={'omitted':True}
   events.append({'method':x['method'],'params':p})
  result={'instrument_valid':not audio['meter_errors'],'kind':'chatgpt-transcript-only-experiment','mode':mode,'cli':'0.163.0','auth_type':auth,'api_key_fallback':False,'proxy_used':False,'version':'v3','output_modality':'text'if mode=='text-modality'else'audio','prompt':prompt,'start_rpc':start,'peer_connected':connected,'fixture_repetitions':repeats,'fixture_bytes_total':len(pcm),'fixture_bytes_sent':track.offset,'audio_stats':audio,'rtp':rtp,'data_events':data,'normal_turn_started':any(x.get('method')=='turn/started'for x in c.events),'wall_seconds':round(time.monotonic()-clock,3),'events':events}
  text=json.dumps(result,indent=2);assert '/Users/'not in text and 'Bearer 'not in text and 'sk-'not in text
  Path(f'results/transcript-only-{mode}.json').write_text(text+'\n');print(text,flush=True)
 finally:
  await pc.close()
  for task in tasks:task.cancel()
  await c.close()
if __name__=='__main__':asyncio.run(run(os.environ.get('TRANSCRIPT_ONLY_MODE','text-modality')))
