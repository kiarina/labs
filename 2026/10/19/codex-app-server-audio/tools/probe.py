#!/usr/bin/env python3
import asyncio,json,os,sys,time
from pathlib import Path

class Client:
 def __init__(self,binary,extra=(),env=None):
  self.binary=binary;self.extra=extra;self.env=env;self.seq=0;self.pending={};self.events=[]
 async def start(self,experimental=True):
  self.proc=await asyncio.create_subprocess_exec(self.binary,'app-server',*self.extra,stdin=-1,stdout=-1,stderr=asyncio.subprocess.DEVNULL,env=self.env)
  self.reader=asyncio.create_task(self.read())
  await self.call('initialize',{'clientInfo':{'name':'audio_protocol_lab','version':'0.1.0'},'capabilities':{'experimentalApi':experimental}})
  self.send({'method':'initialized','params':{}})
  return self
 def send(self,msg):self.proc.stdin.write((json.dumps(msg)+'\n').encode())
 async def read(self):
  while line:=await self.proc.stdout.readline():
   try:m=json.loads(line)
   except ValueError:continue
   if 'id'in m and m['id']in self.pending:self.pending.pop(m['id']).set_result(m)
   else:self.events.append(m)
 async def call(self,method,params):
  self.seq+=1;f=asyncio.get_running_loop().create_future();self.pending[self.seq]=f;self.send({'id':self.seq,'method':method,'params':params});return await asyncio.wait_for(f,30)
 async def until(self,predicate,seconds=10):
  end=time.monotonic()+seconds
  while time.monotonic()<end:
   if any(predicate(x)for x in self.events):return True
   await asyncio.sleep(.05)
  return False
 async def close(self):
  self.proc.stdin.close()
  try:await asyncio.wait_for(self.proc.wait(),5)
  except TimeoutError:self.proc.terminate();await self.proc.wait()
  await self.reader

def public_events(events):
 return [x for x in events if x.get('method','').startswith('thread/realtime/') or x.get('method')=='error']

async def gate_probe(binary,label,experimental=True):
 env=dict(os.environ)
 # Test existing ChatGPT sign-in without a fallback Platform API key.
 env.pop('OPENAI_API_KEY',None)
 c=await Client(binary,['-c','realtime.version="v2"','-c','realtime.type="transcription"'],env).start(experimental)
 try:
  account=await c.call('account/read',{'refreshToken':False});account=account.get('result',{}).get('account')or{}
  t=await c.call('thread/start',{'ephemeral':True,'cwd':str(Path('work').resolve()),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'})
  if 'error'in t:return {'label':label,'thread_error':t['error']}
  tid=t['result']['thread']['id']
  before=await c.call('thread/realtime/appendAudio',{'threadId':tid,'audio':{'data':'AAA=','sampleRate':24000,'numChannels':1}})
  start=await c.call('thread/realtime/start',{'threadId':tid,'outputModality':'text','version':'v2','transport':{'type':'websocket'},'includeStartupContext':False})
  await c.until(lambda x:x.get('method')in ['thread/realtime/error','thread/realtime/closed'],5)
  stop=await c.call('thread/realtime/stop',{'threadId':tid})
  result={'label':label,'account_type':account.get('type'),'experimental':experimental,'append_before_start':before,'start':start,'stop':stop,'events':public_events(c.events)}
  def scrub(x):
   if isinstance(x,dict):return {k:scrub(v)for k,v in x.items()if k not in ['threadId']}
   if isinstance(x,list):return [scrub(v)for v in x]
   return x
  return scrub(result)
 finally:await c.close()

async def main():
 for binary,label in [('work/cli-old/node_modules/.bin/codex','installed-0.159.3'),('work/cli/node_modules/.bin/codex','stable-0.163.0')]:
  for experimental in [False,True]:
   r=await gate_probe(binary,label,experimental);name=f'{label}-experimental-{str(experimental).lower()}'
   Path(f'results/{name}.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r),flush=True)
if __name__=='__main__':asyncio.run(main())
