#!/usr/bin/env python3
"""Loopback-only control plane for the interactive Flutter voice demo."""
import asyncio,json,os,secrets,signal
from pathlib import Path
from urllib.parse import urlsplit,parse_qs
from websockets.asyncio.server import serve
from delegation_probe import Experiment,ROOT,BIN
from probe import Client

class Demo(Experiment):
 def __init__(self,socket):
  super().__init__();self.socket=socket;self.lock=asyncio.Lock();self.tid=None;self.stopping=False
 async def emit(self,kind,**fields):
  try:await self.socket.send(json.dumps({'type':kind,**fields},ensure_ascii=False))
  except Exception:pass
 def event(self,kind,**fields):
  super().event(kind,**fields);asyncio.create_task(self.emit('activity',text=kind))
 async def handle_delegation(self,upstream,event):
  item=event.get('item',{});identifier=item.get('id')or event.get('delegation',{}).get('id')
  if not identifier or any(x['raw_id']==identifier for x in self.delegations):return
  self.delegations.append({'raw_id':identifier})
  text=''.join(x.get('text','')for x in item.get('content',[])if x.get('type')=='input_text')or self.input_text
  async with self.lock:
   if self.stopping:return
   await self.emit('thinker_start',text=text)
   try:
    answer=await self.think(text)
    if self.stopping:return
    await upstream.send(json.dumps({'type':'delegation.context.append','delegation_item_id':identifier,'channel':'commentary','content':[{'type':'input_text','text':answer}]}));self.result_sent=True
    await self.emit('thinker_result',text=answer)
   except Exception as error:await self.emit('error',text='Thinker: '+type(error).__name__)
 async def monitor(self):
  previous_in='';previous_out=''
  while not self.stopping:
   if self.input_text!=previous_in:previous_in=self.input_text;await self.emit('user_transcript',text=previous_in)
   if self.output_text!=previous_out:previous_out=self.output_text;await self.emit('voice_transcript',text=previous_out)
   if self.voice:
    if any(e.get('method')=='turn/started'for e in self.voice.events):await self.emit('error',text='Unexpected built-in voice turn');return
    for e in self.voice.events:
     if e.get('method')=='thread/realtime/error':await self.emit('error',text='音声セッションでエラーが発生しました');return
   await asyncio.sleep(.1)
 async def run(self,offer):
  env=dict(os.environ);env.pop('OPENAI_API_KEY',None)
  await self.prepare_thinker(env)
  # A separate application-owned conversation, with a safe read-only inventory tool.
  t=await self.thinker.call('thread/start',{'ephemeral':True,'cwd':str(ROOT/'work/thinker-sandbox'),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna','baseInstructions':'You are the independent Thinker behind a Japanese voice conversation demo. Answer normal questions naturally in one to three short Japanese sentences, remembering prior turns. For inventory questions use lookup_inventory; A17 has stock and reserved values returned by the tool. Subtract reservations to get available stock. Never invent inventory. Do not use shell, network or filesystem. You may answer other questions using your own reasoning.','dynamicTools':[{'type':'function','name':'lookup_inventory','description':'Look up synthetic A17 inventory','inputSchema':{'type':'object','properties':{'product_code':{'type':'string'}},'required':['product_code'],'additionalProperties':False}}],'config':{'web_search':'disabled','features':{'shell_tool':False}}})
  self.thinker_thread=t['result']['thread']['id']
  async with serve(self.relay,'127.0.0.1',0,max_size=32*1024*1024)as relay:
   port=relay.sockets[0].getsockname()[1]
   self.voice=await Client(BIN,['-c','experimental_realtime_webrtc_call_base_url="https://chatgpt.com/backend-api/wham"','-c',f'experimental_realtime_ws_base_url="http://127.0.0.1:{port}/v1"'],env).start()
   a=await self.voice.call('account/read',{'refreshToken':False});assert a['result']['account']['type']=='chatgpt'
   t=await self.voice.call('thread/start',{'ephemeral':True,'cwd':str(ROOT/'work'),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'});self.tid=t['result']['thread']['id']
   await self.voice.call('thread/realtime/start',{'threadId':self.tid,'version':'v3','outputModality':'audio','includeStartupContext':False,'clientManagedHandoffs':True,'delegationAckFiller':False,'prompt':'You are the Japanese voice Talker of a demo with an independent client Thinker. For every substantive question or request, delegate to the client Thinker and then speak its returned answer naturally and briefly in Japanese. Do not solve tasks or invent tool results yourself. You may greet and acknowledge without delegation. Do not speak endlessly. The user can ask follow-up questions.','transport':{'type':'webrtc','sdp':offer}})
   await self.voice.until(lambda e:e.get('method')in ['thread/realtime/sdp','thread/realtime/error'],25)
   e=next((e for e in self.voice.events if e.get('method')=='thread/realtime/sdp'),None)
   if not e:raise RuntimeError('No SDP answer')
   await self.emit('answer',sdp=e['params']['sdp']);await self.emit('status',text='ChatGPT 接続準備完了')
   monitor=asyncio.create_task(self.monitor())
   try:
    async for raw in self.socket:
     if json.loads(raw).get('type')=='stop':break
   finally:monitor.cancel();self.stopping=True
 async def close(self):
  self.stopping=True
  for t in self.tasks:t.cancel()
  if self.tasks:await asyncio.gather(*self.tasks,return_exceptions=True)
  if self.voice:
   if self.tid:
    try:await self.voice.call('thread/realtime/stop',{'threadId':self.tid})
    except Exception:pass
   await self.voice.close()
  if self.thinker:await self.thinker.close()

async def main():
 token=secrets.token_urlsafe(32);active=False
 async def handler(ws):
  nonlocal active
  u=urlsplit(ws.request.path)
  if u.path!='/demo' or parse_qs(u.query).get('token')!=[token] or ws.request.headers.get('Origin') or active:
   await ws.close(1008,'Unauthorized or busy');return
  active=True;demo=Demo(ws)
  try:
   request=json.loads(await asyncio.wait_for(ws.recv(),20));assert request['type']=='start'
   await demo.run(request['sdp'])
  except Exception as error:await demo.emit('error',text='接続エラー: '+type(error).__name__)
  finally:await demo.close();active=False
 async with serve(handler,'127.0.0.1',0,max_size=2*1024*1024)as server:
  port=server.sockets[0].getsockname()[1];p=ROOT/'work/demo-control.json';p.write_text(json.dumps({'url':f'ws://127.0.0.1:{port}/demo?token={token}'}));p.chmod(0o600)
  print('Voice demo control server ready (loopback only)',flush=True)
  stop=asyncio.Event();loop=asyncio.get_running_loop()
  for sig in [signal.SIGTERM,signal.SIGINT]:loop.add_signal_handler(sig,stop.set)
  try:await stop.wait()
  finally:p.unlink(missing_ok=True)
if __name__=='__main__':asyncio.run(main())
