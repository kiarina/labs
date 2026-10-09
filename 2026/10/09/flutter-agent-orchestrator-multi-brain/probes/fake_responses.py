import json, sys, http.server
out = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers['content-length']))
        with open(out, 'ab') as f: f.write(body + b'\n')
        self.send_response(200); self.send_header('content-type', 'text/event-stream'); self.end_headers()
        item = {"type": "message", "id": "m1", "role": "assistant", "content": [{"type": "output_text", "text": "OK"}]}
        resp = {"id": "r1", "object": "response", "status": "completed", "output": [item],
                "usage": {"input_tokens": 1, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 1, "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 2}}
        for ev, data in [("response.created", {"response": {**resp, "status": "in_progress", "output": []}}),
                         ("response.output_item.added", {"output_index": 0, "item": item}),
                         ("response.output_item.done", {"output_index": 0, "item": item}),
                         ("response.completed", {"response": resp})]:
            self.wfile.write(f"event: {ev}\ndata: {json.dumps({'type': ev, **data})}\n\n".encode())
http.server.HTTPServer(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
