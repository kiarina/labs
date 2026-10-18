#!/usr/bin/env python3
"""Backend-to-voice via app-server's sideband; synthetic silence, no physical mic."""
import asyncio,json,os,time
from array import array
from pathlib import Path
from aiortc import RTCPeerConnection,RTCConfiguration,AudioStreamTrack,RTCSessionDescription
from probe import Client,public_events
async def main():
 env=dict(os.environ);env.pop('OPENAI_API_KEY',None)
 pc=RTCPeerConnection(RTCConfiguration(iceServers=[]));pc.addTrack(AudioStreamTrack());pc.createDataChannel('oai-events');audio={'frames':0,'nonzero_samples':0,'peak_pcm16':0};tasks=[]
 @pc.on('track')
 def track(t):
  async def consume():
   try:
    while True:
     frame=await t.recv();assert frame.format.name=='s16';a=array('h');a.frombytes(bytes(frame.planes[0])[:frame.samples*len(frame.layout.channels)*2]);audio['frames']+=1;audio['nonzero_samples']+=sum(x!=0 for x in a);audio['peak_pcm16']=max(audio['peak_pcm16'],max((abs(x)for x in a),default=0))
   except Exception as error:
    if type(error).__name__!='MediaStreamError':audio['meter_error']=type(error).__name__
  tasks.append(asyncio.create_task(consume()))
 await pc.setLocalDescription(await pc.createOffer())
 c=await Client('work/cli/node_modules/.bin/codex',['-c','experimental_realtime_webrtc_call_base_url="https://chatgpt.com/backend-api/wham"'],env).start();clock=time.monotonic()
 try:
  a=await c.call('account/read',{'refreshToken':False});assert a['result']['account']['type']=='chatgpt'
  t=await c.call('thread/start',{'ephemeral':True,'cwd':str(Path('work').resolve()),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'});tid=t['result']['thread']['id']
  await c.call('thread/realtime/start',{'threadId':tid,'version':'v3','outputModality':'audio','includeStartupContext':False,'clientManagedHandoffs':True,'prompt':'This is a backend communication test, not a request to work. Do not delegate or call tools. Be silent until an announcement arrives from the application. Use the application-provided factual context and announce the requested result briefly in Japanese.','transport':{'type':'webrtc','sdp':pc.localDescription.sdp}})
  await c.until(lambda x:x.get('method')in ['thread/realtime/sdp','thread/realtime/error'],20)
  sdp=next(x['params']['sdp']for x in c.events if x.get('method')=='thread/realtime/sdp');await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp,type='answer'))
  deadline=time.monotonic()+10
  while pc.connectionState not in ['connected','failed']and time.monotonic()<deadline:await asyncio.sleep(.1)
  connected=pc.connectionState=='connected';assert connected
  context='検証用の架空の作業結果です。今回の結果番号は42です。'
  announcement='先ほどアプリから渡された結果番号を、日本語で短く知らせてください。作業の実行や委譲は不要です。'
  text_rpc=await c.call('thread/realtime/appendText',{'threadId':tid,'role':'developer','text':context})
  await asyncio.sleep(1)
  speech_rpc=await c.call('thread/realtime/appendSpeech',{'threadId':tid,'text':announcement})
  deadline=time.monotonic()+12
  while time.monotonic()<deadline:
   if any(x.get('method')=='turn/started'for x in c.events):
    turn=next(x['params']['turn']['id']for x in c.events if x.get('method')=='turn/started');await c.call('turn/interrupt',{'threadId':tid,'turnId':turn});break
   if any(x.get('method')=='thread/realtime/transcript/done'and x['params'].get('role')=='assistant'for x in c.events):break
   await asyncio.sleep(.1)
  await c.call('thread/realtime/stop',{'threadId':tid});await c.until(lambda x:x.get('method')=='thread/realtime/closed',3)
  events=[]
  for x in public_events(c.events):
   p={k:v for k,v in x.get('params',{}).items()if k not in ['threadId','turnId','realtimeSessionId','sessionId','sdp']}
   if 'audio'in p:p['audio']={'omitted':True}
   events.append({'method':x['method'],'params':p})
  result={'kind':'chatgpt-backend-sideband-roundtrip','cli':'0.163.0','auth_type':'chatgpt','api_key_fallback':False,'proxy_used':False,'version':'v3','peer_connected':connected,'physical_microphone_used':False,'context':context,'announcement':announcement,'append_text_rpc':text_rpc,'append_speech_rpc':speech_rpc,'audio_stats':audio,'normal_turn_started':any(x.get('method')=='turn/started'for x in c.events),'wall_seconds':round(time.monotonic()-clock,3),'events':events}
  data=json.dumps(result,indent=2);assert '/Users/'not in data and 'Bearer 'not in data
  Path('results/backend-sideband-roundtrip.json').write_text(data+'\n');print(data)
 finally:
  await pc.close()
  for task in tasks:task.cancel()
  await c.close()
if __name__=='__main__':asyncio.run(main())
