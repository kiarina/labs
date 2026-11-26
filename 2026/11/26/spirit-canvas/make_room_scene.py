"""Writes scenes/spirit-room.json: a room drawn by a web page, and the
spirit's VRM body in the front layer walking about, working at the desk,
dozing by the bed. Touching the body gets a reaction (a script, no model);
the spirit is told later (not woken).

python3 make_room_scene.py
"""

import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))

ROOM = r"""<!doctype html><html lang='ja'><head><meta charset='utf-8'><style>
*{box-sizing:border-box}html,body{margin:0;height:100%;overflow:hidden;font-family:-apple-system,'Segoe UI',sans-serif}
body{background:linear-gradient(#efe4d2,#e6d6bd 78%);}
.wain{position:absolute;left:0;right:0;bottom:20%;height:16%;background:repeating-linear-gradient(90deg,#d9c3a1 0 46px,#d2ba95 46px 48px);border-top:6px solid #c4a77c}
.floor{position:absolute;left:0;right:0;bottom:0;height:20%;background:repeating-linear-gradient(90deg,#b98a5a 0 120px,#ad7f50 120px 122px);box-shadow:inset 0 10px 18px rgba(0,0,0,.18)}
.win{position:absolute;left:34%;top:9%;width:26%;height:38%;border:12px solid #fbf7ef;border-radius:6px;box-shadow:0 6px 14px rgba(0,0,0,.12);overflow:hidden}
.sky{position:absolute;inset:0;background:linear-gradient(#8fc8ef,#d6eefa)}
body.night .sky{background:linear-gradient(#1c2650,#41457a)}
.win:after{content:'';position:absolute;left:50%;top:0;bottom:0;width:10px;margin-left:-5px;background:#fbf7ef}
.cloud{position:absolute;width:90px;height:28px;background:#fff;border-radius:20px;opacity:.9;animation:drift 40s linear infinite}
.cloud:before{content:'';position:absolute;left:18px;top:-16px;width:44px;height:36px;background:#fff;border-radius:50%}
body.night .cloud{opacity:.15}
.star{position:absolute;width:3px;height:3px;background:#fff;border-radius:50%;display:none}
body.night .star{display:block}
@keyframes drift{from{transform:translateX(-120px)}to{transform:translateX(420px)}}
.curtain{position:absolute;top:7%;width:5%;height:44%;background:linear-gradient(90deg,#d97b6c,#e9988a,#d97b6c);border-radius:0 0 10px 10px}
.bed{position:absolute;left:2%;bottom:12%;width:25%;height:17%}
.bed .frame{position:absolute;left:0;right:0;bottom:0;height:45%;background:#8c5e3c;border-radius:6px}
.bed .head{position:absolute;left:0;bottom:0;width:7%;height:150%;background:#7a5032;border-radius:8px 8px 0 0}
.bed .mat{position:absolute;left:5%;right:0;bottom:40%;height:42%;background:#7fa6c9;border-radius:10px}
.bed .pillow{position:absolute;left:9%;bottom:72%;width:26%;height:30%;background:#fff;border-radius:14px}
.desk{position:absolute;right:4%;bottom:14%;width:26%;height:30%}
.desk .top{position:absolute;left:0;right:0;top:34%;height:9%;background:#a06b3e;border-radius:4px}
.desk .leg{position:absolute;top:40%;bottom:0;width:6%;background:#8a5a33}
.laptop{position:absolute;left:30%;top:4%;width:36%;height:31%;background:#2d3340;border-radius:6px 6px 0 0;box-shadow:0 0 22px rgba(120,190,255,.55)}
.laptop:after{content:'';position:absolute;inset:8%;background:linear-gradient(#5aa2e6,#9fd0ff);border-radius:3px;animation:glow 3s ease-in-out infinite alternate}
@keyframes glow{from{opacity:.75}to{opacity:1}}
.mug{position:absolute;left:76%;top:16%;width:9%;height:18%;background:#f2f2f2;border-radius:0 0 8px 8px}
.plant{position:absolute;left:29%;bottom:14%;width:5%;height:12%;background:#c46b4c;border-radius:0 0 10px 10px}
.plant:before{content:'';position:absolute;left:-60%;bottom:90%;width:220%;height:150%;background:radial-gradient(circle at 30% 60%,#5f9a52 30%,transparent 31%),radial-gradient(circle at 70% 50%,#6fae5f 32%,transparent 33%),radial-gradient(circle at 50% 20%,#4f8a45 30%,transparent 31%)}
.shelf{position:absolute;right:7%;top:14%;width:18%;height:5%;background:#a06b3e;border-radius:3px}
.book{position:absolute;bottom:100%;width:12%;border-radius:2px 2px 0 0}
.clock{position:absolute;left:66%;top:11%;width:84px;height:84px;margin-left:-42px;border-radius:50%;background:#fbf7ef;border:6px solid #a06b3e;display:flex;align-items:center;justify-content:center;font-weight:600;color:#5b4632;font-size:20px}
</style></head><body>
<div class='win'><div class='sky'></div><div class='cloud' style='top:22%'></div><div class='cloud' style='top:55%;animation-delay:-18s'></div>
<div class='star' style='left:20%;top:20%'></div><div class='star' style='left:70%;top:35%'></div><div class='star' style='left:45%;top:60%'></div></div>
<div class='curtain' style='left:30%'></div><div class='curtain' style='left:59%'></div>
<div class='clock' id='clock'>--:--</div>
<div class='shelf'><div class='book' style='left:8%;height:260%;background:#c7584a'></div><div class='book' style='left:22%;height:220%;background:#4a7ec7'></div><div class='book' style='left:36%;height:280%;background:#e2b13c'></div><div class='book' style='left:58%;height:200%;background:#5f9a52'></div></div>
<div class='wain'></div><div class='floor'></div>
<div class='bed'><div class='frame'></div><div class='head'></div><div class='mat'></div><div class='pillow'></div></div>
<div class='plant'></div>
<div class='desk'><div class='laptop'></div><div class='mug'></div><div class='top'></div><div class='leg' style='left:4%'></div><div class='leg' style='right:4%'></div></div>
<script>
function tick(){var d=new Date(),h=d.getHours(),m=d.getMinutes();
document.getElementById('clock').textContent=h+':'+(m<10?'0':'')+m;
document.body.classList.toggle('night',h<6||h>=18);}
tick();setInterval(tick,10000);
</script></body></html>"""

SCRIPT = r"""
var ME = 'me', FLOOR = 24;
var W = 0, H = 0, mode = 'idle', timer = null, taps = [];

function pick(list) { return list[Math.floor(Math.random() * list.length)]; }
function nowX() { var e = sg.element(ME); return e && e.now ? e.now.x : 0; }
function later(ms, fn) { if (timer) sg.cancel(timer); timer = sg.after(ms, fn); }

// The body's box: about half the screen tall, narrow enough to stay tight.
function size() {
  H = Math.round(sg.height * 0.5);
  W = Math.round(H * 0.6);
  sg.update(ME, { w: W, h: H, y: -FLOOR });
}

function say(text) {
  var x = Math.max(8, Math.min(sg.width - 288, nowX() + W / 2 - 140));
  sg.update('say', { x: x, y: -(FLOOR + H + 8), text: text, opacity: 1 });
  sg.speak(text, { vrm: ME, id: 'say', interrupt: true });
}
sg.on('spoken', 'say', function () { sg.update('say', { opacity: 0 }, 400); });

function showZ() {
  sg.update('zzz', { x: nowX() + W * 0.62, y: -(FLOOR + H * 0.86), opacity: 1 });
  sg.animate('zzz', { keyframes: [{ at: 0, opacity: 0.25 }, { at: 1, opacity: 1 }], duration_ms: 1400, repeat: -1, alternate: true });
}
function hideZ() { sg.update('zzz', { opacity: 0 }); }

// Walks to x (left edge of the box), side on, then faces the viewer.
function walkTo(x, then) {
  var from = nowX();
  x = Math.max(0, Math.min(sg.width - W, x));
  var d = Math.abs(x - from);
  if (d < 12) { then(); return; }
  var ms = Math.round(d / 140 * 1000);
  mode = 'walk';
  sg.update(ME, { pose: 'walk', turn: x > from ? 90 : -90, look_at_viewer: false, expression: 'neutral' });
  sg.update(ME, { x: x }, ms);
  later(ms + 60, function () { sg.update(ME, { turn: 0, pose: 'idle' }); then(); });
}

function next() {
  hideZ();
  var r = Math.random();
  if (r < 0.45) {
    walkTo(Math.random() * (sg.width - W), function () {
      mode = 'idle';
      sg.update(ME, { look_at_viewer: true });
      later(2000 + Math.random() * 2500, next);
    });
  } else if (r < 0.7) {
    // Beside the desk (its left end is at 70% of the width), facing it.
    walkTo(sg.width * 0.7 - W * 0.62, function () {
      mode = 'work';
      sg.update(ME, { pose: 'work', turn: 70, look_at_viewer: false });
      later(9000 + Math.random() * 6000, next);
    });
  } else if (r < 0.88) {
    walkTo(sg.width * 0.05, function () {
      mode = 'sleep';
      sg.update(ME, { pose: 'sleep', turn: 0, look_at_viewer: false });
      showZ();
      later(10000 + Math.random() * 8000, next);
    });
  } else {
    mode = 'think';
    sg.update(ME, { pose: 'think', look_at_viewer: false });
    later(3500, next);
  }
}

sg.on('tap', ME, function (ev) {
  var v = ev.value || {};
  var e = sg.element(ME);
  var top = e && e.now ? e.now.y : 0;
  sg.update(ME, { x: nowX() });  // stop where it is
  hideZ();
  var t = Date.now();
  taps = taps.filter(function (a) { return t - a < 6000; });
  taps.push(t);
  var was = mode;
  mode = 'react';
  if (was === 'sleep') {
    sg.update(ME, { pose: 'idle', turn: 0, expression: 'surprised', expression_weight: 0.8, look_at_viewer: true });
    say(pick(['ふぁっ…寝てないよ、ほんとだよ。', 'むにゃ…あ、おはよう。']));
    sg.notify('ユーザーが、うたた寝していた体をつついて起こした', { wake: false });
  } else if (taps.length >= 4) {
    sg.update(ME, { pose: 'idle', turn: 0, expression: 'angry', expression_weight: 0.6, look_at_viewer: true });
    say('もう、くすぐったいってば！');
    taps = [];
    sg.notify('ユーザーが体を何度もつついた', { wake: false });
  } else if (v.y !== undefined && v.y < top + H * 0.28) {
    sg.update(ME, { pose: 'nod', turn: 0, expression: 'happy', expression_weight: 0.9, look_at_viewer: true });
    say(pick(['えへへ、なでてくれるの？', '頭はちょっと照れるな。']));
  } else if (was === 'work') {
    sg.update(ME, { pose: 'idle', turn: 0, expression: 'relaxed', look_at_viewer: true });
    say(pick(['いま作業中だけど、どうしたの？', 'ちょうど一息つきたかったところ。']));
  } else {
    sg.update(ME, { pose: 'wave', turn: 0, expression: 'happy', expression_weight: 0.8, look_at_viewer: true });
    say(pick(['なあに？', '呼んだ？', 'こんにちは！', 'あそびに来てくれたの？']));
  }
  later(4500, function () { sg.update(ME, { expression: 'neutral' }); next(); });
});

size();
sg.update(ME, { x: Math.round(sg.width * 0.42) });
later(1500, next);
"""

scene = {
    "name": "spirit-room",
    "description": "部屋の背景（Web）の上で、精霊の体（VRM）が歩き回り、机で仕事をし、ベッドのそばでうたた寝する。体に触ると反応する（頭をなでる・寝ているのを起こす・何度もつつくと怒る）。モデルなしで動き、触ったことは後で精霊に伝わる。",
    "params": {},
    "background": "#e6d6bd",
    "elements": [
        {"id": "room", "type": "web", "x": 0, "y": 0, "w": "100%", "h": "100%", "html": ROOM},
        {"id": "me", "type": "vrm", "layer": "front", "anchor": "bottom-left", "x": 500, "y": -24,
         "w": 240, "h": 400, "framing": "full", "pose": "idle", "tappable": True, "look_at_viewer": True},
        {"id": "zzz", "type": "text", "layer": "front", "anchor": "bottom-left", "x": 0, "y": -300,
         "w": 90, "h": 44, "text": "Z z z", "size": 26, "weight": "bold", "color": "#6b7fb3", "opacity": 0},
        {"id": "say", "type": "text", "layer": "front", "anchor": "bottom-left", "x": 0, "y": -440,
         "w": 280, "h": 56, "text": "", "size": 20, "align": "center", "color": "#3a2f25",
         "background": "#FFFFFFEE", "radius": 18, "opacity": 0},
    ],
    "state": {},
    "timelines": {},
    "scripts": {"wander": SCRIPT.strip() + "\n"},
}

with open(os.path.join(HERE, "scenes", "spirit-room.json"), "w") as f:
    json.dump(scene, f, ensure_ascii=False, indent=1)
print("wrote scenes/spirit-room.json")
