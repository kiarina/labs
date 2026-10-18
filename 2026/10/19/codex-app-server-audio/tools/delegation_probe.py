#!/usr/bin/env python3
"""Real voice delegation -> application-owned Codex Thinker -> bound spoken result.
Only a loopback sideband adapter and synthetic inventory/speech are used.
"""
import asyncio,json,os,time,hashlib,re
from array import array
from pathlib import Path
from websockets.asyncio.server import serve
from websockets.asyncio.client import connect
from aiortc import RTCPeerConnection,RTCConfiguration,RTCSessionDescription
from probe import Client,public_events
from webrtc_audio import FixtureTrack
ROOT=Path(__file__).resolve().parent.parent
BIN='work/cli/node_modules/.bin/codex'

class Experiment:
 def __init__(self):
  self.clock=time.monotonic();self.timeline=[];self.input_text='';self.output_text='';self.output_after_result='';self.delegations=[];self.tasks=[];self.result_sent=False;self.errors=[];self.tool_calls=[];self.thinker_result=None;self.completed=asyncio.Event();self.voice=None;self.thinker=None;self.thinker_thread=None;self.catalog=None;self.auth_receipts=[]
 def event(self,kind,**fields):self.timeline.append({'at_seconds':round(time.monotonic()-self.clock,3),'kind':kind,**fields})
 async def prepare_thinker(self,env):
  source=Path.home()/'.codex/models_cache.json';cache=json.loads(source.read_text());models=[x for x in cache['models']if x['slug']=='gpt-6-luna'];assert len(models)==1
  model={**models[0],'tool_mode':None,'multi_agent_version':None,'apply_patch_tool_type':None,'supports_search_tool':False,'experimental_supported_tools':[],'include_skills_usage_instructions':False,'include_apps_usage_instructions':False,'include_plugin_usage_instructions':False,'node_repl_disabled':True}
  catalog=ROOT/'work/thinker-direct-catalog.json';catalog.write_text(json.dumps({'models':[model]}));self.catalog={'source':'existing model metadata cache, read only','model':'gpt-6-luna','tool_mode':None,'catalog_sha256':hashlib.sha256(catalog.read_bytes()).hexdigest()}
  self.thinker=await Client(BIN,['-c',f'model_catalog_json="{catalog}"'],env).start()
  a=await self.thinker.call('account/read',{'refreshToken':False});assert a['result']['account']['type']=='chatgpt'
  t=await self.thinker.call('thread/start',{'ephemeral':True,'cwd':str(ROOT/'work/thinker-sandbox'),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna','baseInstructions':'You are an independent inventory Thinker in an integration test. Use only lookup_inventory to verify stock and reserved quantity, then subtract reserved from stock. Interpret A seventeen or エー十七 as A17. Never use shell, files, network, or any other tool. Return exactly one short Japanese sentence with the product code and available quantity. Do not guess inventory.','dynamicTools':[{'type':'function','name':'lookup_inventory','description':'Read stock and reserved units from the application-owned synthetic inventory. Must be called before answering an inventory question.','inputSchema':{'type':'object','properties':{'product_code':{'type':'string'}},'required':['product_code'],'additionalProperties':False}}],'config':{'web_search':'disabled','features':{'shell_tool':False}}})
  if 'error'in t:raise RuntimeError(t['error'])
  self.thinker_thread=t['result']['thread']['id'];self.event('thinker_ready',model='gpt-6-luna')
 async def think(self,text):
  self.event('thinker_started');self.thinker.events.clear()
  await self.thinker.call('turn/start',{'threadId':self.thinker_thread,'input':[{'type':'text','text':text}],'effort':'low'})
  deadline=time.monotonic()+45;answer=''
  while time.monotonic()<deadline:
   while self.thinker.events:
    e=self.thinker.events.pop(0);m=e.get('method');p=e.get('params',{})
    if m=='item/tool/call':
     assert p['tool']=='lookup_inventory',p['tool'];args=p['arguments'];args=json.loads(args)if isinstance(args,str)else args;code=args.get('product_code','').upper();assert code=='A17',code
     row=json.loads((ROOT/'fixtures/delegation-inventory.json').read_text())['items'][code]
     self.tool_calls.append({'tool':p['tool'],'arguments':args,'result':row});self.event('inventory_tool_called',product_code=code)
     self.thinker.send({'id':e['id'],'result':{'success':True,'contentItems':[{'type':'inputText','text':json.dumps(row,ensure_ascii=False)}]}})
    elif m=='item/agentMessage/delta':answer+=p['delta']
    elif m=='turn/completed':
     status=p['turn']['status'];assert status=='completed',status;assert answer.strip(),'empty Thinker result';self.event('thinker_completed');return answer.strip()
    elif m=='error':raise RuntimeError('Thinker error')
    elif 'id'in e and m:self.thinker.send({'id':e['id'],'result':{'decision':'decline'}})
   await asyncio.sleep(.05)
  raise TimeoutError('Thinker timeout')
 async def handle_delegation(self,upstream,event):
  item=event.get('item',{});identifier=item.get('id')or event.get('delegation',{}).get('id');assert identifier
  if any(x['raw_id']==identifier for x in self.delegations):return
  entry={'raw_id':identifier,'local_id':f'd{len(self.delegations)+1}','forwarded_to_builtin_codex':False,'input_transcript_at_receipt':self.input_text};self.delegations.append(entry)
  self.event('delegation_received',delegation=entry['local_id'])
  if len(self.delegations)>1:self.errors.append('more than one delegation');return
  # Legacy Codex may include text; modern public delegation only has metadata.
  content=''.join(x.get('text','')for x in item.get('content',[])if x.get('type')=='input_text')
  request=(content or self.input_text).strip();entry['request_to_thinker']=request
  try:
   answer=await self.think(request);self.thinker_result=answer
   command={'type':'delegation.context.append','delegation_item_id':identifier,'channel':'commentary','content':[{'type':'input_text','text':answer}]}
   await upstream.send(json.dumps(command));self.result_sent=True;entry['returned_to_same_delegation']=True;self.event('result_returned',delegation=entry['local_id'])
  except Exception as error:self.errors.append(type(error).__name__);self.event('thinker_failed',error_type=type(error).__name__)
 async def relay(self,downstream):
  path=downstream.request.path;assert re.fullmatch(r'/v1/live/rtc_[A-Za-z0-9_-]+',path),path
  allowed={'authorization','chatgpt-account-id','openai-alpha','originator','user-agent','x-session-id','x-codex-turn-metadata','openai-beta'}
  headers={k:v for k,v in downstream.request.headers.raw_items()if k.lower()in allowed}
  self.auth_receipts.append({'authorization_present':any(k.lower()=='authorization'for k in headers),'account_header_present':any(k.lower()=='chatgpt-account-id'for k in headers),'destination':'api.openai.com/v1/live/[call-id]','credential_values_saved':False})
  async with connect('wss://api.openai.com'+path,additional_headers=headers,max_size=32*1024*1024)as upstream:
   self.event('sideband_connected')
   async def app_to_voice():
    async for raw in downstream:await upstream.send(raw)
   async def voice_to_app():
    async for raw in upstream:
     try:e=json.loads(raw)
     except (ValueError,TypeError):await downstream.send(raw);continue
     kind=e.get('type')
     if kind=='input_transcript.added':self.input_text+=e.get('item',{}).get('text','')
     elif kind=='output_transcript.added':
      delta=e.get('item',{}).get('text','');self.output_text+=delta
      if self.result_sent:self.output_after_result+=delta
     elif kind=='turn.done'and e.get('turn',{}).get('role')=='assistant'and self.result_sent:self.completed.set()
     elif kind=='error':self.errors.append({'voice_error':e.get('error',{}).get('message','')[:250]})
     if kind in ['delegation.created','session.delegation.created']:
      self.tasks.append(asyncio.create_task(self.handle_delegation(upstream,e)));continue
     await downstream.send(raw)
   pair=[asyncio.create_task(app_to_voice()),asyncio.create_task(voice_to_app())]
   try:
    done,pending=await asyncio.wait(pair,return_when=asyncio.FIRST_COMPLETED)
    for t in pending:t.cancel()
    for t in done:
     try:t.result()
     except Exception as error:
      if 'ConnectionClosed'not in type(error).__name__:self.errors.append(type(error).__name__)
   finally:
    for t in pair:t.cancel()

async def main():
 x=Experiment();env=dict(os.environ);env.pop('OPENAI_API_KEY',None);pc=RTCPeerConnection(RTCConfiguration(iceServers=[]));pcm=(ROOT/'work/delegation-request.pcm').read_bytes();track=FixtureTrack(pcm);pc.addTrack(track);dc=pc.createDataChannel('oai-events');audio={'frames':0,'nonzero_samples_after_result':0,'peak_after_result_pcm16':0};audio_tasks=[]
 @pc.on('track')
 def on_track(t):
  async def consume():
   try:
    while True:
     f=await t.recv();audio['frames']+=1
     if x.result_sent:
      assert f.format.name=='s16';a=array('h');a.frombytes(bytes(f.planes[0])[:f.samples*len(f.layout.channels)*2]);audio['nonzero_samples_after_result']+=sum(v!=0 for v in a);audio['peak_after_result_pcm16']=max(audio['peak_after_result_pcm16'],max((abs(v)for v in a),default=0))
   except Exception as error:
    if type(error).__name__!='MediaStreamError':audio['meter_error']=type(error).__name__
  audio_tasks.append(asyncio.create_task(consume()))
 await pc.setLocalDescription(await pc.createOffer());connected=False
 try:
  await x.prepare_thinker(env)
  async with serve(x.relay,'127.0.0.1',0,max_size=32*1024*1024)as server:
   port=server.sockets[0].getsockname()[1]
   x.voice=await Client(BIN,['-c','experimental_realtime_webrtc_call_base_url="https://chatgpt.com/backend-api/wham"','-c',f'experimental_realtime_ws_base_url="http://127.0.0.1:{port}/v1"'],env).start()
   a=await x.voice.call('account/read',{'refreshToken':False});assert a['result']['account']['type']=='chatgpt'
   t=await x.voice.call('thread/start',{'ephemeral':True,'cwd':str(ROOT/'work'),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'});tid=t['result']['thread']['id']
   await x.voice.call('thread/realtime/start',{'threadId':tid,'version':'v3','outputModality':'audio','includeStartupContext':False,'clientManagedHandoffs':True,'delegationAckFiller':False,'prompt':'You are the voice Talker in an integration test. The user will ask for inventory in the application database. You have NO inventory facts. Always delegate that lookup to the client backend; never guess or calculate an inventory number yourself. Wait for the delegated result, then state the available quantity briefly in Japanese. You may briefly acknowledge the request. Do not call any backend other than client delegation.','transport':{'type':'webrtc','sdp':pc.localDescription.sdp}})
   await x.voice.until(lambda e:e.get('method')in ['thread/realtime/sdp','thread/realtime/error'],20)
   sdp=next(e['params']['sdp']for e in x.voice.events if e.get('method')=='thread/realtime/sdp');await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp,type='answer'));deadline=time.monotonic()+10
   while pc.connectionState not in ['connected','failed']and time.monotonic()<deadline:await asyncio.sleep(.1)
   connected=pc.connectionState=='connected';assert connected;x.event('voice_peer_connected');track.enabled=True
   deadline=time.monotonic()+65
   while time.monotonic()<deadline:
    if any(e.get('method')=='turn/started'for e in x.voice.events):
     x.errors.append('builtin voice backing turn unexpectedly started');break
    if x.completed.is_set()or x.errors:break
    await asyncio.sleep(.1)
   if x.tasks:await asyncio.gather(*x.tasks,return_exceptions=True)
   await asyncio.sleep(.4)
   await x.voice.call('thread/realtime/stop',{'threadId':tid});await x.voice.until(lambda e:e.get('method')=='thread/realtime/closed',3)
   result={'kind':'voice-to-application-owned-thinker-delegation','cli':'0.163.0','voice_auth':'chatgpt','thinker_auth':'chatgpt','thinker_model':'gpt-6-luna','api_key_fallback':False,'physical_microphone_used':False,'architecture':'WebRTC voice + loopback sideband adapter suppressing builtin handoff + separate Thinker app-server','peer_connected':connected,'fixture_pcm_sha256':hashlib.sha256(pcm).hexdigest(),'fixture_bytes_sent':track.offset,'fixture_bytes_total':len(pcm),'synthetic_request':'商品コード A17 の在庫を調べ、予約分を引いた利用可能数を日本語で教えてください。','inventory_source':'fixtures/delegation-inventory.json','delegations':[{k:v for k,v in d.items()if k!='raw_id'}for d in x.delegations],'tool_calls':x.tool_calls,'thinker_result':x.thinker_result,'voice_input_transcript':x.input_text,'voice_output_transcript':x.output_text,'voice_output_after_result':x.output_after_result,'audio_stats':audio,'voice_builtin_turns':sum(e.get('method')=='turn/started'for e in x.voice.events),'auth_receipts':x.auth_receipts,'catalog':x.catalog,'errors':x.errors,'timeline':x.timeline,'wall_seconds':round(time.monotonic()-x.clock,3)}
   data=json.dumps(result,indent=2);assert '/Users/'not in data and 'Bearer 'not in data and 'sk-'not in data
   (ROOT/'results/thinker-delegation-roundtrip.json').write_text(data+'\n');print(data,flush=True)
 finally:
  await pc.close()
  for task in audio_tasks+x.tasks:task.cancel()
  if x.voice:await x.voice.close()
  if x.thinker:await x.thinker.close()
if __name__=='__main__':asyncio.run(main())
