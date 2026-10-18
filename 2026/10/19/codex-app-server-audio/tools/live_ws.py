#!/usr/bin/env python3
"""Opt-in tiny paid smoke. Needs OPENAI_API_KEY; never logs key or raw audio."""
import asyncio,base64,json,os,hashlib,time
from pathlib import Path
from probe import Client,public_events

async def run(mode):
 assert os.environ.get('OPENAI_API_KEY'),'No Platform API key in environment'
 extra=['-c','model_provider="audio_lab"','-c','model_providers.audio_lab.name="Audio lab"','-c','model_providers.audio_lab.base_url="http://127.0.0.1:9/v1"','-c','model_providers.audio_lab.env_key="OPENAI_API_KEY"','-c','model_providers.audio_lab.wire_api="responses"','-c','realtime.version="v2"','-c',f'realtime.type="{mode}"','-c','experimental_realtime_ws_base_url="https://api.openai.com/v1"']
 if os.environ.get('TRANSCRIPTION_INTENT')=='1':extra[-1]='experimental_realtime_ws_base_url="https://api.openai.com/v1?intent=transcription"'
 c=await Client('work/cli/node_modules/.bin/codex',extra).start()
 pcm=Path('work/fixture.pcm').read_bytes();clock=time.monotonic();sent=0
 try:
  t=await c.call('thread/start',{'ephemeral':True,'cwd':str(Path('work').resolve()),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'})
  tid=t['result']['thread']['id']
  start=await c.call('thread/realtime/start',{'threadId':tid,'outputModality':'text','version':'v2','transport':{'type':'websocket'},'includeStartupContext':False,'clientManagedHandoffs':True,'model':'gpt-realtime-mini','prompt':'This is a short audio transcription test. Listen without calling any tools or delegating any task. If a response is necessary, say only OK.'})
  ready=await c.until(lambda x:x.get('method')in ['thread/realtime/started','thread/realtime/error'],15)
  started=any(x.get('method')=='thread/realtime/started'for x in c.events)
  if started:
   # 100 ms PCM16 mono frames, followed by silence for server VAD, in real time.
   audio=pcm+b'\x00\x00'*24000
   for k in range(0,len(audio),4800):
    if any(x.get('method')in ['thread/realtime/error','thread/realtime/closed']for x in c.events):break
    block=audio[k:k+4800]
    await c.call('thread/realtime/appendAudio',{'threadId':tid,'audio':{'data':base64.b64encode(block).decode(),'sampleRate':24000,'numChannels':1,'samplesPerChannel':len(block)//2}})
    sent+=len(block);await asyncio.sleep(.1)
   await c.until(lambda x:x.get('method')=='thread/realtime/transcript/done' and x.get('params',{}).get('role')=='user',8)
  await c.call('thread/realtime/stop',{'threadId':tid});await c.until(lambda x:x.get('method')=='thread/realtime/closed',3)
  events=[]
  for x in public_events(c.events):
   p={k:v for k,v in x.get('params',{}).items()if k not in ['threadId','turnId','realtimeSessionId','sessionId']}
   if 'audio'in p:
    a=p['audio'];b=base64.b64decode(a.pop('data'));a.update(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
   events.append({'method':x['method'],'params':p})
  r={'kind':'live-openai-platform-smoke','mode':mode,'version':'0.163.0','intent_override':os.environ.get('TRANSCRIPTION_INTENT')=='1','realtime_model':'gpt-realtime-mini','started':started,'start_rpc':start,'sent_bytes':sent,'fixture_bytes':len(pcm),'fixture_sha256':hashlib.sha256(pcm).hexdigest(),'wall_seconds':round(time.monotonic()-clock,3),'normal_turn_started':any(x.get('method')=='turn/started'for x in c.events),'events':events}
  text=json.dumps(r,indent=2)
  key=os.environ['OPENAI_API_KEY'];text=text.replace(key,'[REDACTED]')
  assert '/Users/'not in text
  suffix='-intent' if os.environ.get('TRANSCRIPTION_INTENT')=='1' else ''
  Path(f'results/live-{mode}{suffix}.json').write_text(text+'\n');print(text,flush=True)
 finally:await c.close()
if __name__=='__main__':asyncio.run(run(os.environ.get('LIVE_MODE','transcription')))
