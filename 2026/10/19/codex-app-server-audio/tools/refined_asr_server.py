#!/usr/bin/env python3
"""One persistent ChatGPT voice call with timestamp-preserving sideband relay."""
import asyncio,json,os,re,secrets,signal,base64,time
from audio_clock import AudioClock
from urllib.parse import urlsplit,parse_qs
from websockets.asyncio.server import serve
from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed
from probe import Client
from delegation_probe import ROOT,BIN
from asr_server import STRONG_PROMPT

async def main():
 token=secrets.token_urlsafe(32);active=False
 async def handler(ws):
  nonlocal active
  u=urlsplit(ws.request.path)
  if u.path!='/refined' or parse_qs(u.query).get('token')!=[token] or ws.request.headers.get('Origin') or active:
   await ws.close(1008,'Unauthorized or busy');return
  clock=AudioClock();clock_task=None
  active=True;client=None;tid=None;seq=0;started=asyncio.Event();upstream=None
  async def relay(down):
   nonlocal seq,upstream
   assert re.fullmatch(r'/v1/live/rtc_[A-Za-z0-9_-]+',down.request.path)
   headers={k:v for k,v in down.request.headers.raw_items()if k.lower()in ['authorization','chatgpt-account-id','openai-alpha','originator','user-agent','x-session-id','x-codex-turn-metadata','openai-beta']}
   try:
    async with connect('wss://api.openai.com'+down.request.path,additional_headers=headers,max_size=32*1024*1024)as up:
     upstream=up;started.set()
     async def app_to_voice():
      try:
       async for raw in down:await up.send(raw)
      except ConnectionClosed:pass
     forward=asyncio.create_task(app_to_voice())
     try:
      async for raw in up:
       e=json.loads(raw);kind=e.get('type','')
       if kind=='session.input_audio.append':clock.reflected_input(base64.b64decode(e['audio']))
       if kind=='session.output_audio.delta'and isinstance(e.get('end_ms'),(int,float)):clock.reflected_output(e['end_ms'])
       if kind in ['input_transcript.added','output_transcript.added','session.input_transcript.delta','session.output_transcript.delta']:
        seq+=1
        await ws.send(json.dumps({'type':'transcript','seq':seq,'role':'user'if'input_transcript'in kind else'assistant','delta':e.get('item',{}).get('text',e.get('delta','')),'start_ms':e.get('start_ms'),'end_ms':e.get('end_ms')}))
       if kind=='delegation.created':
        await ws.send(json.dumps({'type':'unexpected_delegation'}));continue
       if kind=='error':await ws.send(json.dumps({'type':'error','text':'upstream_error'}))
       await down.send(raw)
     finally:forward.cancel();upstream=None
   except ConnectionClosed:pass
  try:
   req=json.loads(await asyncio.wait_for(ws.recv(),20));assert req['type']=='start'
   env=dict(os.environ);env.pop('OPENAI_API_KEY',None)
   async with serve(relay,'127.0.0.1',0,max_size=32*1024*1024)as sideband:
    port=sideband.sockets[0].getsockname()[1]
    client=await Client(BIN,['-c','experimental_realtime_webrtc_call_base_url="https://chatgpt.com/backend-api/wham"','-c',f'experimental_realtime_ws_base_url="http://127.0.0.1:{port}/v1"'],env).start()
    a=await client.call('account/read',{'refreshToken':False});assert a['result']['account']['type']=='chatgpt'
    t=await client.call('thread/start',{'ephemeral':True,'cwd':str(ROOT/'work'),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'});tid=t['result']['thread']['id']
    await client.call('thread/realtime/start',{'threadId':tid,'version':'v3','outputModality':'audio','includeStartupContext':False,'clientManagedHandoffs':True,'prompt':STRONG_PROMPT,'transport':{'type':'webrtc','sdp':req['sdp']}})
    assert await client.until(lambda e:e.get('method')in ['thread/realtime/sdp','thread/realtime/error'],25)
    sdp=next(e['params']['sdp']for e in client.events if e.get('method')=='thread/realtime/sdp')
    await ws.send(json.dumps({'type':'answer','sdp':sdp,'auth':'chatgpt','connections':1}))
    async def align():
     try:
      while True:
       await asyncio.sleep(1)
       update=clock.update()
       if update:await ws.send(json.dumps({'type':'clock_alignment',**update}))
     except ConnectionClosed:pass
    clock_task=asyncio.create_task(align())
    async for raw in ws:
     e=json.loads(raw)
     if e.get('type')=='stop':
      await ws.send(json.dumps({'type':'clock_summary',**clock.summary()}));break
     if e.get('type')=='clock_report':await ws.send(json.dumps({'type':'clock_summary',**clock.summary()}))
     if e.get('type')=='audio_reference':clock.reference(base64.b64decode(e['audio']),e['device_ms'])
     if e.get('type')=='ping':await ws.send(json.dumps({'type':'pong','echo':e.get('value')}))
  except ConnectionClosed:pass
  except Exception as error:
   try:await ws.send(json.dumps({'type':'error','text':type(error).__name__}))
   except Exception:pass
  finally:
   if clock_task:clock_task.cancel()
   if client:
    if tid:
     try:await client.call('thread/realtime/stop',{'threadId':tid})
     except Exception:pass
    await client.close()
   active=False
 async with serve(handler,'127.0.0.1',0,max_size=2*1024*1024)as server:
  port=server.sockets[0].getsockname()[1];p=ROOT/'work/refined-control.json';p.write_text(json.dumps({'url':f'ws://127.0.0.1:{port}/refined?token={token}'}));p.chmod(0o600);print('Persistent ASR control ready',flush=True)
  stop=asyncio.Event()
  for sig in [signal.SIGTERM,signal.SIGINT]:asyncio.get_running_loop().add_signal_handler(sig,stop.set)
  try:await stop.wait()
  finally:p.unlink(missing_ok=True)
if __name__=='__main__':asyncio.run(main())
