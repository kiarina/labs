"""Model-free check of a talk: slides in a web element, the VRM in the front
layer over them, and a script that speaks each slide's lines and moves on at
each `spoken`. Drives the running app through its control port.

python3 present_check.py [name] [port]   put the talk, record what happens and
                                         pictures under work/logs/<name>/
"""

import base64
import json
import sys
import os
import time
import urllib.parse
import urllib.request

NAME = sys.argv[1] if len(sys.argv) > 1 else "macos"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else int(os.environ.get("CONTROL_PORT", "8813"))
BASE = f"http://127.0.0.1:{PORT}"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "work", "logs", NAME)

SLIDES = """<!doctype html><html><head><meta charset='utf-8'><style>
body{margin:0;font-family:-apple-system,'Segoe UI',sans-serif;background:#F4F1EA;color:#2B2B2B}
.s{display:none;position:absolute;inset:0;padding:56px 72px;box-sizing:border-box}
.s.on{display:block}
h1{font-size:52px;margin:0 0 24px;color:#3B5B8C}
li{font-size:30px;margin:14px 0}
.n{position:absolute;left:72px;bottom:32px;font-size:20px;color:#888}
#next{position:absolute;right:40%;bottom:28px;font-size:22px;padding:10px 22px}
</style></head><body>
<div class='s on'><h1>精霊のキャンバス</h1><ul><li>会話の画面が、そのまま舞台になる</li><li>文字・絵・音・ページを自由に置ける</li></ul></div>
<div class='s'><h1>WebView の上に体を重ねる</h1><ul><li>スライドはページ、体は前面の層</li><li>体の下でもページは押せる</li></ul></div>
<div class='s'><h1>声に合わせて口が動く</h1><ul><li>端末の声で読み上げる</li><li>読み終わると次へ進む</li></ul></div>
<div class='n'><span id='p'>1</span> / 3</div>
<button id='next' onclick='go(cur+1)'>次へ</button>
<script>
var cur=0;var all=document.querySelectorAll('.s');
function go(i){if(i>=all.length)i=0;all[cur].classList.remove('on');cur=i;all[cur].classList.add('on');
document.getElementById('p').textContent=cur+1;sg.setState({slide:cur+1});sg.emit('slide',{n:cur+1},{wake:false});}
sg.setState({slide:1});
</script></body></html>"""

LINES = [
    ["こんにちは。今日は、精霊のキャンバスを紹介します。", "会話の画面が、そのまま舞台になります。"],
    ["スライドはウェブのページで、わたしの体は、その上の層に重ねています。"],
    ["わたしの口は、この声の大きさに合わせて動いています。", "以上です。ありがとうございました。"],
]

SCRIPT = """
var lines = %s;
var slide = 0, line = 0;
function say() {
  sg.speak(lines[slide][line], {vrm: 'me', id: 's' + slide + '-' + line, caption: 'cap'});
}
sg.on('spoken', '*', function () {
  line++;
  if (line >= lines[slide].length) {
    slide++; line = 0;
    if (slide >= lines.length) { sg.set('done', 1); return; }
    sg.web('slides', 'go(' + slide + ')');
  }
  say();
});
say();
""" % json.dumps(LINES, ensure_ascii=False)


def call(path, body=None):
    data = None if body is None else json.dumps(body, ensure_ascii=False).encode()
    req = urllib.request.Request(BASE + path, data=data, method="POST" if data is not None or path not in ("/state",) else "GET")
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def tool(name, args):
    r = call("/tool?" + urllib.parse.urlencode({"name": name}), args)
    print(name, "->", r["text"][:200])
    return r


def snap(label):
    r = call("/snapshot?" + urllib.parse.urlencode({"name": label, "inline": "1"}), {})
    path = os.path.join(OUT, f"present-{label}.png")
    if r.get("png"):
        with open(path, "wb") as f:
            f.write(base64.b64decode(r["png"]))
    print("snapshot", label, path if r.get("png") else r)
    return path


def main():
    os.makedirs(OUT, exist_ok=True)
    tool("canvas_clear", {"background": "#202020"})
    tool("canvas_put", {"elements": [
        {"id": "slides", "type": "web", "x": 0, "y": 0, "w": "100%", "h": "100%", "html": SLIDES},
        {"id": "me", "type": "vrm", "layer": "front", "anchor": "bottom-right", "x": 0, "y": 0,
         "w": "34%", "h": "70%", "framing": "bust", "expression": "happy", "expression_weight": 0.4},
        {"id": "cap", "type": "text", "layer": "front", "anchor": "bottom", "x": 0, "y": -96,
         "w": "60%", "h": 56, "text": "", "size": 24, "align": "center", "color": "#FFFFFF",
         "background": "#000000AA", "radius": 12},
    ]})
    time.sleep(4)
    tool("canvas_script", {"id": "talk", "code": SCRIPT})
    t0 = time.time()
    seen = []
    while time.time() - t0 < 90:
        v = json.loads(tool("canvas_view", {"image": False})["text"])
        state = v.get("state", {})
        seen.append({"t": round(time.time() - t0, 1), "state": state, "web": v.get("web")})
        if len(seen) in (2, 6):
            snap(f"talk-{len(seen)}")
        if state.get("done"):
            break
        time.sleep(2)
    with open(os.path.join(OUT, "present-check.json"), "w") as f:
        json.dump(seen, f, ensure_ascii=False, indent=1)
    print("seconds", round(time.time() - t0, 1), "done", bool(seen[-1]["state"].get("done")))


if __name__ == "__main__":
    main()
