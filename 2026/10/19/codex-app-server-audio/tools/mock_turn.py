#!/usr/bin/env python3
"""Capture an ordinary turn's request locally. Never calls an inference service."""
import asyncio,base64,io,json,os,threading,wave
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from probe import Client
captured=[]
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_POST(self):
  raw=self.rfile.read(int(self.headers['Content-Length']));body=json.loads(raw);captured.append(body)
  events=[{'type':'response.created','response':{'id':'mock-response'}},{'type':'response.completed','response':{'id':'mock-response','status':'completed','output':[],'usage':{'input_tokens':1,'output_tokens':0,'total_tokens':1}}}]
  self.send_response(200);self.send_header('Content-Type','text/event-stream');self.end_headers()
  for e in events:self.wfile.write(('data: '+json.dumps(e)+'\n\n').encode())
async def main():
 server=ThreadingHTTPServer(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start();port=server.server_address[1]
 env=dict(os.environ,OPENAI_API_KEY='lab-dummy-never-valid')
 extra=['-c','model_provider="audio_lab"','-c','model_providers.audio_lab.name="Audio lab"','-c',f'model_providers.audio_lab.base_url="http://127.0.0.1:{port}/v1"','-c','model_providers.audio_lab.env_key="OPENAI_API_KEY"','-c','model_providers.audio_lab.wire_api="responses"']
 c=await Client('work/cli/node_modules/.bin/codex',extra,env).start()
 try:
  t=await c.call('thread/start',{'ephemeral':True,'cwd':str(Path('work').resolve()),'approvalPolicy':'never','sandbox':'read-only','model':'gpt-6-luna'})
  tid=t['result']['thread']['id'];buf=io.BytesIO()
  with wave.open(buf,'wb')as w:w.setnchannels(1);w.setsampwidth(2);w.setframerate(24000);w.writeframes(b'\x00\x00'*2400)
  await c.call('turn/start',{'threadId':tid,'input':[{'type':'text','text':'Protocol fixture. Reply OK without tools.'},{'type':'audio','url':'data:audio/wav;base64,'+base64.b64encode(buf.getvalue()).decode()}]})
  done=await c.until(lambda x:x.get('method')=='turn/completed',15)
  text=json.dumps(captured);r={'kind':'mock-responses-no-inference','model':'gpt-6-luna','request_count':len(captured),'turn_completed':done,'input_audio_present':'"input_audio"'in text,'omission_marker_present':'audio content omitted because you do not support audio input'in text}
  assert r['request_count']>0 and not r['input_audio_present']and r['omission_marker_present'],r
  Path('results/mock-normal-turn.json').write_text(json.dumps(r,indent=2)+'\n');print(r)
 finally:await c.close();server.shutdown();server.server_close()
if __name__=='__main__':asyncio.run(main())
