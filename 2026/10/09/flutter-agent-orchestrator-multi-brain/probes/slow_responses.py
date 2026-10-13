# A fake OpenAI Responses API that answers "OK" after a delay (seconds), so a
# worker stays running long enough to watch (a shared body in use, a thinker at
# work). Also answers GET /models. No tokens.
#   python3 probes/slow_responses.py <port> <delay>
import json, sys, time, http.server, socketserver
delay = float(sys.argv[2])
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        body = json.dumps({"data": [{"id": "fake-model"}]}).encode()
        self.send_response(200); self.send_header('content-type', 'application/json'); self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        self.rfile.read(int(self.headers['content-length']))
        self.send_response(200); self.send_header('content-type', 'text/event-stream'); self.end_headers()
        item = {"type": "message", "id": "m1", "role": "assistant", "content": [{"type": "output_text", "text": "OK"}]}
        resp = {"id": "r1", "object": "response", "status": "completed", "output": [item],
                "usage": {"input_tokens": 1, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 1, "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 2}}
        def ev(e, d): self.wfile.write(f"event: {e}\ndata: {json.dumps({'type': e, **d})}\n\n".encode()); self.wfile.flush()
        ev("response.created", {"response": {**resp, "status": "in_progress", "output": []}})
        time.sleep(delay)
        ev("response.output_item.added", {"output_index": 0, "item": item})
        ev("response.output_item.done", {"output_index": 0, "item": item})
        ev("response.completed", {"response": resp})
class S(socketserver.ThreadingMixIn, http.server.HTTPServer): daemon_threads = True
S(('127.0.0.1', int(sys.argv[1])), H).serve_forever()
