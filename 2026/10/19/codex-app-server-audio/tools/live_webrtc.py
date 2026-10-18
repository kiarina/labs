#!/usr/bin/env python3
"""ChatGPT-auth WebRTC smoke with generated silence; no microphone or key fallback."""
import asyncio,json,os,time,hashlib
from pathlib import Path
from aiortc import RTCPeerConnection,RTCConfiguration,AudioStreamTrack,RTCSessionDescription
from probe import Client,public_events

async def main():
 version=os.environ.get('REALTIME_VERSION','v3')
 env=dict(os.environ);env.pop('OPENAI_API_KEY',None)
 pc=RTCPeerConnection(RTCConfiguration(iceServers=[]));pc.addTrack(AudioStreamTrack());pc.createDataChannel('oai-events')
 await pc.setLocalDescription(await pc.createOffer())
 c=await Client('work/cli/node_modules/.bin/codex',env=env).start();clock=time.monotonic();negotiated=False;connection=False
 try:
  t=await c.call('thread/start',{'ephemeral':True,'cwd':str(Path('work').resolve()),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'})
  tid=t['result']['thread']['id']
  start=await c.call('thread/realtime/start',{'threadId':tid,'outputModality':('text' if version=='v2' else 'audio'),'version':version,'includeStartupContext':False,'clientManagedHandoffs':True,'model':'gpt-realtime-mini','prompt':'A transport connection test. Remain silent and never delegate.','transport':{'type':'webrtc','sdp':pc.localDescription.sdp}})
  await c.until(lambda x:x.get('method')in ['thread/realtime/sdp','thread/realtime/error'],20)
  sdp=next((x['params']['sdp']for x in c.events if x.get('method')=='thread/realtime/sdp'),None)
  if sdp:
   await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp,type='answer'));negotiated=True
   end=time.monotonic()+8
   while time.monotonic()<end and pc.connectionState not in ['connected','failed']:await asyncio.sleep(.1)
   connection=pc.connectionState=='connected'
  await c.call('thread/realtime/stop',{'threadId':tid});await c.until(lambda x:x.get('method')=='thread/realtime/closed',3)
  events=[]
  for x in public_events(c.events):
   p={k:v for k,v in x.get('params',{}).items()if k not in ['threadId','turnId','realtimeSessionId','sessionId','sdp']}
   if 'audio'in p:p['audio']={'omitted':True}
   # Error may contain a request id; keep diagnostic text, omit local SDP/IPs.
   events.append({'method':x['method'],'params':p})
  r={'kind':'live-chatgpt-auth-webrtc-smoke','cli':'0.163.0','aiortc':'1.15.0','api_key_fallback':False,'version':version,'realtime_model':'gpt-realtime-mini','start_rpc':start,'answer_received':negotiated,'peer_connected':connection,'peer_state':pc.connectionState,'normal_turn_started':any(x.get('method')=='turn/started'for x in c.events),'wall_seconds':round(time.monotonic()-clock,3),'events':events}
  text=json.dumps(r,indent=2);assert '/Users/'not in text
  Path(f'results/live-chatgpt-webrtc-{version}.json').write_text(text+'\n');print(text)
 finally:await pc.close();await c.close()
if __name__=='__main__':asyncio.run(main())
