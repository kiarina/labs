#!/usr/bin/env python3
import http.server,json,os
from pathlib import Path
lab=Path(__file__).resolve().parent.parent
class Handler(http.server.SimpleHTTPRequestHandler):
 def end_headers(self):
  self.send_header('Cross-Origin-Opener-Policy','same-origin');self.send_header('Cross-Origin-Embedder-Policy','require-corp');super().end_headers()
 def do_POST(self):
  if self.path!='/report':self.send_error(404);return
  data=self.rfile.read(int(self.headers['Content-Length']));r=json.loads(data)
  (lab/'work'/('report-web-'+r['mode']+'.json')).write_text(json.dumps(r,indent=2))
  self.send_response(200);self.end_headers();self.wfile.write(b'ok')
os.chdir(lab/'app/build/web')
http.server.ThreadingHTTPServer(('127.0.0.1',8798),Handler).serve_forever()
