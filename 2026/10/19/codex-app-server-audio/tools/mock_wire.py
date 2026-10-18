#!/usr/bin/env python3
import asyncio,base64,json,os,hashlib
from pathlib import Path
from websockets.asyncio.server import serve
from probe import Client,public_events

async def run(mode):
 captured=[];received=asyncio.Event()
 pcm=b'\x00\x00'*2400
 async def handler(ws):
  await ws.send(json.dumps({'type':'session.created','session':{'id':'mock-session'}}))
  async for raw in ws:
   m=json.loads(raw);captured.append(m)
   if m['type']=='session.update':
    await ws.send(json.dumps({'type':'session.updated','session':{'id':'mock-session'}}))
   if m['type']=='input_audio_buffer.append':
    for event in [
     {'type':'conversation.item.input_audio_transcription.delta','item_id':'fixture-input','content_index':0,'delta':'fixture '},
     {'type':'conversation.item.input_audio_transcription.completed','item_id':'fixture-input','content_index':0,'transcript':'fixture transcript'},
     {'type':'response.output_audio.delta','delta':base64.b64encode(pcm).decode()},
     {'type':'response.output_text.delta','delta':'fixture answer'},
     {'type':'response.output_text.done','text':'fixture answer'}]:
     await ws.send(json.dumps(event))
    received.set()
 async with serve(handler,'127.0.0.1',0)as server:
  port=server.sockets[0].getsockname()[1]
  env=dict(os.environ,OPENAI_API_KEY='lab-dummy-never-valid')
  extra=['-c','realtime.version="v2"','-c',f'realtime.type="{mode}"','-c',f'experimental_realtime_ws_base_url="http://127.0.0.1:{port}/v1"']
  c=await Client('work/cli/node_modules/.bin/codex',extra,env).start()
  try:
   t=await c.call('thread/start',{'ephemeral':True,'cwd':str(Path('work').resolve()),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'})
   tid=t['result']['thread']['id']
   start=await c.call('thread/realtime/start',{'threadId':tid,'outputModality':'text','version':'v2','includeStartupContext':False,'clientManagedHandoffs':True,'transport':{'type':'websocket'},'prompt':'Protocol fixture; never delegate or execute tools.'})
   assert await c.until(lambda x:x.get('method')=='thread/realtime/started',10),public_events(c.events)
   audio=base64.b64encode(pcm).decode()
   # Deliberately mismatched metadata. Verify transport forwards bytes, not conversion.
   append=await c.call('thread/realtime/appendAudio',{'threadId':tid,'audio':{'data':audio,'sampleRate':16000,'numChannels':2,'samplesPerChannel':1200}})
   await asyncio.wait_for(received.wait(),10)
   assert await c.until(lambda x:x.get('method')=='thread/realtime/transcript/done' and x.get('params',{}).get('role')=='assistant',10), public_events(c.events)
   await asyncio.sleep(.2)
   stop=await c.call('thread/realtime/stop',{'threadId':tid})
   await c.until(lambda x:x.get('method')=='thread/realtime/closed',5)
   session=next(x['session']for x in captured if x['type']=='session.update')
   forwarded=next(x for x in captured if x['type']=='input_audio_buffer.append')
   events=[]
   for x in public_events(c.events):
    p={k:v for k,v in x.get('params',{}).items()if k not in ['threadId','realtimeSessionId']}
    if 'audio'in p:
     b=base64.b64decode(p['audio'].pop('data'));p['audio'].update(bytes=len(b),sha256=hashlib.sha256(b).hexdigest())
    events.append({'method':x['method'],'params':p})
   result={'kind':'mock-upstream-no-ASR-inference','mode':mode,'start':start,'append':append,'stop':stop,'session_type':session['type'],'audio_config':session.get('audio'),'tool_names':[x['name']for x in session.get('tools',[])],'upstream_types':[x['type']for x in captured],'forwarded_bytes_unchanged':forwarded['audio']==audio,'forwarded_fields':list(forwarded),'normal_turn_started':any(x.get('method')=='turn/started'for x in c.events),'events':events}
   assert result['forwarded_bytes_unchanged'];assert not result['normal_turn_started']
   Path(f'results/mock-{mode}.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
  finally:await c.close()
async def main():
 for mode in ['transcription','conversational']:await run(mode)
if __name__=='__main__':asyncio.run(main())
