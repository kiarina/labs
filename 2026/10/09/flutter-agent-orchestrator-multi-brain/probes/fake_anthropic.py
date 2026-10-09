# Fake Anthropic Messages API: records each request body, answers "OK" as a stream.
import json, sys, http.server
out = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self): self.send_response(404); self.end_headers()
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('content-length', 0)))
        with open(out, 'ab') as f: f.write(json.dumps({'path': self.path, 'body': json.loads(body or b'{}')}).encode() + b'\n')
        if 'count_tokens' in self.path:
            self.send_response(200); self.send_header('content-type','application/json'); self.end_headers()
            self.wfile.write(b'{"input_tokens": 1}'); return
        self.send_response(200); self.send_header('content-type', 'text/event-stream'); self.end_headers()
        evs = [
          ('message_start', {'type':'message_start','message':{'id':'msg_1','type':'message','role':'assistant','model':'claude-haiku-5-5','content':[],'stop_reason':None,'stop_sequence':None,'usage':{'input_tokens':1,'output_tokens':1}}}),
          ('content_block_start', {'type':'content_block_start','index':0,'content_block':{'type':'text','text':''}}),
          ('content_block_delta', {'type':'content_block_delta','index':0,'delta':{'type':'text_delta','text':'OK'}}),
          ('content_block_stop', {'type':'content_block_stop','index':0}),
          ('message_delta', {'type':'message_delta','delta':{'stop_reason':'end_turn','stop_sequence':None},'usage':{'output_tokens':1}}),
          ('message_stop', {'type':'message_stop'})]
        for e, d in evs: self.wfile.write(f'event: {e}\ndata: {json.dumps(d)}\n\n'.encode())
http.server.ThreadingHTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
