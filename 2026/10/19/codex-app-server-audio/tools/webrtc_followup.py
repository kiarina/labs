#!/usr/bin/env python3
"""Observe/fix one call-create field; existing ChatGPT auth is forwarded only in RAM."""
import asyncio,json,os,time,threading,urllib.request,urllib.error,hashlib
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from aiortc import RTCPeerConnection,RTCConfiguration,AudioStreamTrack,RTCSessionDescription
from probe import Client,public_events

TARGET='https://chatgpt.com/backend-api/codex/realtime/calls'
async def run(mode):
 assert mode in ['observe','omit-model','sdp-only','empty-session','public-live-model','no-legacy-query','wham-route']
 observations=[]
 class Relay(BaseHTTPRequestHandler):
  def log_message(self,*args):pass
  def do_POST(self):
   assert self.path.split('?')[0]=='/backend-api/codex/realtime/calls'
   body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
   session=body['session'];o={'session_fields':sorted(session),'session_model':session.get('model'),'alpha_header':self.headers.get('OpenAI-Alpha'),'authorization_present':bool(self.headers.get('Authorization')),'account_header_present':bool(self.headers.get('ChatGPT-Account-ID')),'sdp_present':bool(body.get('sdp'))};observations.append(o)
   if mode=='observe':
    self.send_response(400);self.end_headers();self.wfile.write(b'{"error":{"message":"local capture only; upstream not called"}}');return
   if mode=='omit-model':session.pop('model',None)
   if mode=='sdp-only':body.pop('session',None)
   if mode=='empty-session':body['session']={}
   if mode=='public-live-model':body['session']['model']='gpt-live-1'
   o['forwarded_session_fields']=sorted(body.get('session',{}))
   o['forwarded_body_fields']=sorted(body)
   o['url_query']=self.path.split('?',1)[1] if '?'in self.path else ''
   o['forwarded_body_contains_model_key']='\"model\"'in json.dumps(body)
   headers={k:v for k,v in self.headers.items()if k.lower()not in ['host','content-length','connection','accept-encoding']}
   query=('?' + self.path.split('?',1)[1]if '?'in self.path else '')
   if mode=='no-legacy-query':query=''
   o['forwarded_query']=query
   target=TARGET.replace('/codex/','/wham/') if mode=='wham-route' else TARGET
   o['target_route']='wham' if mode=='wham-route' else 'codex'
   req=urllib.request.Request(target+query,data=json.dumps(body).encode(),headers=headers,method='POST')
   try:response=urllib.request.urlopen(req,timeout=20)
   except urllib.error.HTTPError as error:response=error
   except Exception as error:
    o['transport_error_type']=type(error).__name__;self.send_response(502);self.end_headers();self.wfile.write(b'{"error":{"message":"relay transport failed"}}');return
   data=response.read();o['upstream_status']=response.status;o['location_present']=bool(response.headers.get('Location'))
   if response.status!=200 and response.status!=201:
    try:o['upstream_error']=json.loads(data)
    except ValueError:o['upstream_error']={'non_json':True}
   self.send_response(response.status)
   for name in ['Content-Type','Location']:
    if value:=response.headers.get(name):self.send_header(name,value)
   self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
 server=ThreadingHTTPServer(('127.0.0.1',0),Relay);threading.Thread(target=server.serve_forever,daemon=True).start();port=server.server_address[1]
 env=dict(os.environ);env.pop('OPENAI_API_KEY',None)
 pc=RTCPeerConnection(RTCConfiguration(iceServers=[]));pc.addTrack(AudioStreamTrack());pc.createDataChannel('oai-events')
 await pc.setLocalDescription(await pc.createOffer())
 extra=['-c',f'experimental_realtime_webrtc_call_base_url="http://127.0.0.1:{port}/backend-api/codex"']
 c=await Client('work/cli/node_modules/.bin/codex',extra,env).start();clock=time.monotonic();sdp=None;connected=False;states=[]
 @pc.on('connectionstatechange')
 async def state():states.append(pc.connectionState)
 try:
  account=await c.call('account/read',{'refreshToken':False});auth_type=(account.get('result',{}).get('account')or{}).get('type');assert auth_type=='chatgpt'
  t=await c.call('thread/start',{'ephemeral':True,'cwd':str(Path('work').resolve()),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'})
  tid=t['result']['thread']['id']
  start=await c.call('thread/realtime/start',{'threadId':tid,'outputModality':'audio','version':'v3','includeStartupContext':False,'clientManagedHandoffs':True,'prompt':'A short transport test. Remain silent. Never delegate tasks or use tools.','transport':{'type':'webrtc','sdp':pc.localDescription.sdp}})
  await c.until(lambda x:x.get('method')in ['thread/realtime/sdp','thread/realtime/error'],25)
  sdp=next((x['params']['sdp']for x in c.events if x.get('method')=='thread/realtime/sdp'),None)
  if sdp:
   await pc.setRemoteDescription(RTCSessionDescription(sdp=sdp,type='answer'))
   end=time.monotonic()+10
   while time.monotonic()<end and pc.connectionState not in ['connected','failed']:await asyncio.sleep(.1)
   connected=pc.connectionState=='connected'
   if connected:await asyncio.sleep(1)
  await c.call('thread/realtime/stop',{'threadId':tid});await c.until(lambda x:x.get('method')=='thread/realtime/closed',3)
  events=[]
  for x in public_events(c.events):
   p={k:v for k,v in x.get('params',{}).items()if k not in ['threadId','turnId','realtimeSessionId','sessionId','sdp']}
   if 'audio'in p:p['audio']={'omitted':True}
   events.append({'method':x['method'],'params':p})
  result={'adapter_changes':{'observe':['capture only; no upstream request'],'omit-model':['remove session.model'],'empty-session':['replace session with empty object'],'sdp-only':['remove session object'],'public-live-model':['replace session.model with gpt-live-1'],'no-legacy-query':['remove intent and architecture query'],'wham-route':['change call-create route from codex to wham only']}[mode],'kind':'chatgpt-webrtc-followup','mode':mode,'cli':'0.163.0','auth_type':auth_type,'api_key_fallback':False,'model_override':False,'start_rpc':start,'requests':observations,'answer_received':bool(sdp),'peer_connected':connected,'peer_state':pc.connectionState,'connection_states':states,'normal_turn_started':any(x.get('method')=='turn/started'for x in c.events),'wall_seconds':round(time.monotonic()-clock,3),'events':events}
  text=json.dumps(result,indent=2);assert '/Users/'not in text and 'Bearer 'not in text and 'sk-'not in text
  Path(f'results/webrtc-followup-{mode}.json').write_text(text+'\n');print(text,flush=True)
 finally:await pc.close();await c.close();server.shutdown();server.server_close()
if __name__=='__main__':asyncio.run(run(os.environ.get('FOLLOWUP_MODE','observe')))
