"""Model-free checks of the canvas on a device, through its control port.

python3 check_device.py <platform name> <port>

Each step runs canvas tools as the spirit would, then records what came
back and a picture (the app's own capture, web pages drawn in where the
platform can) under work/logs/<platform>/. Prints a summary.
"""

import base64
import json
import os
import sys
import time
import urllib.parse
import urllib.request

name, port = sys.argv[1], int(sys.argv[2])
B = f"http://127.0.0.1:{port}"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "work", "logs", name)
os.makedirs(OUT, exist_ok=True)
results = {}


def post(path, body=None):
    data = json.dumps(body).encode() if body is not None else b""
    req = urllib.request.Request(B + path, data=data, method="POST")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read())


def get(path):
    with urllib.request.urlopen(B + path, timeout=30) as r:
        return json.loads(r.read())


def tool(n, args):
    return post(f"/tool?name={n}", args)


def shot(label):
    r = post(f"/snapshot?name={label}&inline=1")
    if r.get("png"):
        with open(os.path.join(OUT, f"{label}.png"), "wb") as f:
            f.write(base64.b64decode(r["png"]))
        return f"{label}.png"
    return None


def view_text():
    return json.loads(tool("canvas_view", {"image": False})["text"])


def web(id_, js):
    return tool("canvas_web_eval", {"id": id_, "js": js})["text"]


def step(label, fn):
    t = time.time()
    try:
        results[label] = {"ok": True, "result": fn()}
    except Exception as e:  # noqa: BLE001
        results[label] = {"ok": False, "error": repr(e)}
    results[label]["seconds"] = round(time.time() - t, 2)
    print(f"[{label}] {json.dumps(results[label], ensure_ascii=False)[:400]}")


# 1. Every element type (VRM, video, svg, choices, input, audio), fixed design.
def demo():
    post("/demo")
    time.sleep(4)
    v = view_text()
    return {"canvas": v["canvas"], "elements": len(v["elements"]), "picture": shot("1-demo")}


# 2. Screen size and % / anchor.
def layout():
    tool("canvas_clear", {"background": "#1B2233"})
    tool("canvas_put", {"elements": [
        {"id": "title", "type": "text", "anchor": "top", "x": 0, "y": 24, "w": "90%", "h": 60,
         "text": "大きさに合わせる", "size": 28, "align": "center", "weight": "bold"},
        {"id": "card", "type": "shape", "anchor": "center", "x": 0, "y": 0, "w": "80%", "h": "40%",
         "fill": "#2E3A5C", "radius": 24},
        {"id": "ok", "type": "button", "anchor": "bottom-right", "x": -16, "y": -16, "w": 140, "h": 52,
         "label": "OK"},
    ]})
    time.sleep(1)
    v = view_text()
    return {"canvas": v["canvas"], "at": {e["id"]: e.get("at") for e in v["elements"]}, "picture": shot("2-layout")}


# 3. Script (JS engine), state and templates, timeline, on-actions, sounds.
def behaviors():
    tool("canvas_clear", {"background": "#20283A"})
    tool("canvas_put", {"elements": [
        {"id": "clock", "type": "text", "x": 24, "y": 40, "w": "90%", "h": 60, "text": "{{time}}", "size": 40},
        {"id": "count", "type": "text", "x": 24, "y": 110, "w": "90%", "h": 40, "text": "押した回数 {{n}}", "size": 24},
        {"id": "btn", "type": "button", "x": 24, "y": 170, "w": 160, "h": 52, "label": "押す",
         "on": {"press": [{"do": "add", "key": "n"}, {"do": "sound", "src": "sounds/sfx/correct.wav"}]}},
        {"id": "slide", "type": "text", "x": 24, "y": 250, "w": "90%", "h": 40, "text": "", "size": 24},
    ]})
    err = tool("canvas_script", {"id": "clock", "code":
        "function p(n){return (n<10?'0':'')+n}"
        "function s(){var d=new Date();sg.set('time',p(d.getHours())+':'+p(d.getMinutes())+':'+p(d.getSeconds()))}"
        "s();sg.every(1000,s);"
        "sg.on('resize','canvas',function(e){sg.set('size',e.value.width+'x'+e.value.height)});"})["text"]
    tool("canvas_timeline", {"id": "t", "repeat": -1, "cycle_ms": 900, "steps": [
        {"at_ms": 0, "actions": [{"do": "update", "id": "slide", "props": {"text": "1枚目"}}]},
        {"at_ms": 450, "actions": [{"do": "update", "id": "slide", "props": {"text": "2枚目"}}]},
    ]})
    tool("canvas_audio", {"bgm": {"src": "sounds/bgm/calm.wav", "volume": 0.3, "fade_ms": 500}})
    for _ in range(3):
        post("/event?" + urllib.parse.urlencode({"kind": "press", "id": "btn"}))
    time.sleep(2.2)
    st = get("/state")
    pic = shot("3-behaviors")
    tool("canvas_audio", {"bgm": {"stop": True, "fade_ms": 300}})
    return {"script": err, "state": st["behaviors"]["state"], "bgm": st["behaviors"].get("bgm"),
            "notices": st["notices"][-2:], "picture": pic}


# 4. Web element: asset:// (HTML, CSS, added later), events out, state in, audio, picture.
def webview():
    page = json.load(open(os.path.join(HERE, "results", "web-test-page.json")))
    page["elements"][0].update(x=0, y=0, w="100%", h="100%")
    tool("canvas_clear", {"background": "#111111"})
    tool("canvas_put", page)
    # The first page load starts the web view's processes: wait for it.
    t0 = time.time()
    while time.time() - t0 < 15:
        if web("page", "document.readyState === 'complete' && document.images.length > 0") == "true":
            break
        time.sleep(0.5)
    load_s = round(time.time() - t0, 1)
    time.sleep(1)
    imgs = web("page", "Array.from(document.images).map(function(i){return [i.src.split('/').pop(), i.naturalWidth]})")
    bg = web("page", "getComputedStyle(document.querySelector('.bg')).backgroundImage.slice(0,60)")
    web("page", "document.getElementById('b').click(); document.getElementById('b').click(); 'ok'")
    time.sleep(1.5)
    imgs2 = web("page", "Array.from(document.images).map(function(i){return [i.src.split('/').pop(), i.naturalWidth]})")
    audio = web("page", "var a=new Audio('asset://sounds/sfx/chime.wav'); a.play().then(function(){sg.log('played ok')}).catch(function(e){sg.log('audio fail '+e)}); 'started'")
    time.sleep(1)
    v = view_text()
    st = get("/state")
    return {"first_load_s": load_s, "images": imgs, "css_bg": bg, "images_after_clicks": imgs2, "audio": audio,
            "state_seen": v.get("web"), "events": st["notices"][-2:],
            "viewport": web("page", "[innerWidth, innerHeight, devicePixelRatio]"),
            "picture": shot("4-web")}


# 5. Saved scenes: the escape game (fixed design), the mole game (web, fixed design), the planner (web, fills).
def scenes():
    out = {}
    for n in ["space-station-escape", "mole-garden", "today-planner"]:
        r = tool("canvas_load", {"name": n})["text"]
        time.sleep(2.5)
        out[n] = {"load": r, "picture": shot(f"5-{n}"), "canvas": view_text()["canvas"]}
    # Play the planner: tick the first item inside the page.
    out["today-planner"]["tick"] = web("today-planner", "document.querySelector('label.task').click(); JSON.stringify(sg.state)")
    time.sleep(0.8)
    out["today-planner"]["picture_after_tick"] = shot("5-today-planner-ticked")
    return out


for label, fn in [("demo", demo), ("layout", layout), ("behaviors", behaviors), ("web", webview), ("scenes", scenes)]:
    step(label, fn)

with open(os.path.join(OUT, "results.json"), "w") as f:
    json.dump(results, f, ensure_ascii=False, indent=1)
print("saved", os.path.relpath(OUT, HERE))
