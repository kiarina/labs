"""Writes scenes/spirit-isle.json (Part 12): how far the 3D canvas goes. A
floating island garden in a physical sky, from dusk to night and morning:
a pond that reflects, a cherry tree shedding petals, pines, a torii, stone
lanterns that light the path, a floating crystal with rings, a glowing
spiral and magic around it, grass and flowers by the thousand, stars and a
moon at night, fireflies over the pond, small islands drifting, and the
spirit standing in it. Bloom, fog, god rays, ambient occlusion, reflections
and a grade finish it. Without the model:

- the HUD's 夕暮れ / 夜 / 朝: the sun moves and the garden follows
- the crystal: a burst of sparkles, the crystal flares, the spirit speaks
- a lantern: on and off
- the pond: sparkles where it was touched
- the spirit: a reaction by the part touched
- 寄る: the camera goes up to the spirit, the background blurs
- ひと回り: the camera goes round the island and back

python3 make_isle_scene.py
"""

import json
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
W = "isle"
HOME = {"cam_x": -1.2, "cam_y": 2.3, "cam_z": -7.2, "look_x": 0.8, "look_y": 1.0, "look_z": 2.4, "fov": 48}
CRYSTAL = (2.7, 2.4)  # x, z

els = []


def put(id, type, **p):
    e = {"id": id, "type": type, "in": W}
    e.update(p)
    els.append(e)
    return e


# --- the world: sky, sun and finish ---------------------------------------
els.append({
    "id": W, "type": "world", "x": 0, "y": 0, "w": "100%", "h": "100%",
    "sky": "physical", "sun_elevation": 6, "sun_azimuth": 28, "light": 3,
    "bloom": 0.12, "bloom_threshold": 1.6, "fog": 0.007, "fog_color": "#E8B898",
    "exposure": 1.05, "warmth": 0.22, "saturation": 1.1, "vignette": 0.35,
    "god_rays": 0.5, "ao": True, "reflections": True, **HOME,
})

# --- the island -----------------------------------------------------------
put("ground", "cylinder", y=-0.5, z=2, w=17, h=0.5, d=17, color="#5D8A47", roughness=0.95)
put("ground-rim", "cylinder", y=-1.3, z=2, w=17.4, h=0.8, d=17.4, color="#6E5240", roughness=1)
put("rock", "cone", y=-1.3, z=2, rx=180, w=17, h=8, d=17, color="#5C4636", roughness=1)
# Grass in three strips round the pond, and flowers.
GREENS = ["#4F8A3A", "#5E9C44", "#6FAE4E", "#3F7531", "#7DB85A"]
for i, (x, z, w, d, n) in enumerate([(0, 7.6, 15, 4.2, 1500), (4.3, 1.3, 7, 8.4, 1500), (-3.6, -2.4, 7.8, 4.6, 1000)]):
    put(f"grass{i}", "scatter", shape="cone", x=x, z=z, w=w, d=d, count=n, seed=i + 3,
        size=[0.12, 0.34], stretch=[0.16, 1, 0.16], colors=GREENS, roughness=0.9)
for i, (x, z, w, d) in enumerate([(0, 7.6, 14, 4), (4.3, 1.3, 6.6, 8), (-3.6, -2.4, 7.4, 4.2)]):
    put(f"flowers{i}", "scatter", shape="sphere", x=x, z=z, w=w, d=d, count=140, seed=20 + i,
        size=[0.05, 0.09], colors=["#FFFFFF", "#FFD3E2", "#FFE27A", "#C9A7FF"], roughness=0.6)
put("pebbles", "scatter", shape="sphere", x=-3.4, z=3.2, w=6.2, d=4.6, count=90, seed=7,
    size=[0.06, 0.18], stretch=[1.4, 0.5, 1], colors=["#8E8A84", "#A39E96", "#77736D"])

# The pond: dark and smooth, so it reflects (screen-space reflections).
put("pond", "cylinder", x=-3.4, y=-0.02, z=3.2, w=4.6, h=0.05, d=3.4, color="#16304A",
    roughness=0.04, metallic=0.4, tappable=True)
for i in range(14):
    a = i / 14 * 2 * math.pi
    put(f"rim{i}", "sphere", x=round(-3.4 + 2.45 * math.cos(a), 2), z=round(3.2 + 1.85 * math.sin(a), 2), y=-0.08,
        w=0.55, h=0.3, d=0.45, ry=round(math.degrees(a)), color="#8F8A82", roughness=0.95)

# The path to the torii, stepping stones.
for i in range(9):
    put(f"step{i}", "cylinder", x=0.18 * (1 if i % 2 else -1), y=0, z=round(-1.2 + i * 0.95, 2),
        w=0.62, h=0.06, d=0.5, color="#A8A39A", roughness=0.9)

# --- trees ------------------------------------------------------------------
for i, (x, z, s) in enumerate([(5.6, 6.6, 1.1), (6.8, 3.6, 0.9), (4.0, 8.3, 1.25), (-1.8, 8.6, 1.0),
                              (-6.6, 0.4, 1.15), (7.2, 0.2, 0.85), (-7.0, 5.8, 0.95), (6.2, -2.6, 1.0)]):
    put(f"pine{i}-trunk", "cylinder", x=x, z=z, w=0.22 * s, h=1.0 * s, d=0.22 * s, color="#5B3D2A")
    for j, (y, w, h) in enumerate([(0.7, 1.6, 1.3), (1.4, 1.25, 1.1), (2.0, 0.85, 0.95)]):
        put(f"pine{i}-{j}", "cone", x=x, z=z, y=round(y * s, 2), w=round(w * s, 2), h=round(h * s, 2),
            d=round(w * s, 2), color=["#2F5E3A", "#356B41", "#3C7848"][j], roughness=0.85)
# The cherry tree by the pond, and its petals.
put("cherry-trunk", "cylinder", x=-5.8, z=4.8, rz=-8, w=0.34, h=2.3, d=0.34, color="#5A3A2A")
for j, (dx, y, dz, s) in enumerate([(0, 2.0, 0, 1.9), (-0.7, 2.4, 0.4, 1.4), (0.8, 2.3, -0.3, 1.5),
                                    (0.2, 2.9, 0.2, 1.3), (-0.3, 1.9, -0.7, 1.2)]):
    put(f"cherry{j}", "sphere", x=round(-5.6 + dx, 2), y=y, z=round(4.8 + dz, 2), w=s, h=round(s * 0.8, 2), d=s,
        color=["#F6B6CB", "#F9C7D7", "#F2A6BF", "#FBD3E0", "#F4B0C6"][j], roughness=0.8)
put("petals", "particles", preset="petals", x=-5.2, y=1.6, z=4.6, w=4, h=2.2, d=3.6, rate=14)

# --- the torii and its sign ----------------------------------------------------
for i, x in enumerate([-1.15, 1.15]):
    put(f"torii-post{i}", "cylinder", x=x, z=8.3, w=0.24, h=2.7, d=0.24, color="#C8372D", roughness=0.5)
put("torii-top", "box", y=2.62, z=8.3, w=3.4, h=0.2, d=0.34, color="#2A2522", roughness=0.6)
put("torii-beam", "box", y=2.15, z=8.3, w=2.7, h=0.14, d=0.22, color="#C8372D", roughness=0.5)
put("sign", "text", y=3.05, z=8.2, w=420, h=120, size_m=0.5, face_camera=True, text="精霊の庭", size=60,
    align="center", color="#FFF6E6", background="#00000066", radius=24)

# --- stone lanterns along the path (lit at night) ---------------------------
LAMPS = []
for i, z in enumerate([0.2, 2.6, 5.0, 7.0]):
    for side, x in (("l", -1.05), ("r", 1.05)):
        n = f"lamp{i}{side}"
        LAMPS.append(n)
        put(f"{n}-post", "cylinder", x=x, z=z, w=0.18, h=0.62, d=0.18, color="#8C877E", roughness=0.95)
        put(f"{n}", "box", x=x, y=0.62, z=z, w=0.3, h=0.28, d=0.3, color="#F2D2A0", glow=0.3,
            glow_color="#FFB45A", roughness=0.7, tappable=True)
        put(f"{n}-cap", "cone", x=x, y=0.9, z=z, w=0.48, h=0.26, d=0.48, color="#6E6A63", roughness=0.95)
        put(f"{n}-light", "light", x=x, y=0.76, z=z, color="#FFB060", intensity=0.4, range=4.5, flicker=True)

# --- the crystal ------------------------------------------------------------------
cx, cz = CRYSTAL
put("pedestal", "cylinder", x=cx, z=cz, w=1.1, h=0.35, d=1.1, color="#9C978F", roughness=0.9)
put("pedestal-top", "cylinder", x=cx, y=0.35, z=cz, w=0.8, h=0.12, d=0.8, color="#B8B2A8", roughness=0.8)
put("crystal", "cone", x=cx, y=1.45, z=cz, w=0.62, h=0.95, d=0.62, color="#7FE8FF", glow=2.2,
    roughness=0.1, metallic=0.2, opacity=0.92, tappable=True)
put("crystal-low", "cone", x=cx, y=1.45, z=cz, rx=180, w=0.62, h=0.55, d=0.62, color="#7FE8FF", glow=2.2,
    roughness=0.1, metallic=0.2, opacity=0.92, tappable=True)
def ring(r, n=24):
    return [[round(r * math.cos(i / n * 2 * math.pi), 3), 0, round(r * math.sin(i / n * 2 * math.pi), 3)] for i in range(n + 1)]
put("ring-a", "tube", x=cx, y=1.45, z=cz, rx=12, points=ring(0.75), radius=0.022, color="#E7C35A", metallic=1, roughness=0.25)
put("ring-b", "tube", x=cx, y=1.45, z=cz, rx=-20, rz=30, points=ring(0.95), radius=0.016, color="#E7C35A", metallic=1, roughness=0.25)
helix = [[round(0.95 * math.cos(t * 0.5), 3), round(0.25 + t * 0.09, 3), round(0.95 * math.sin(t * 0.5), 3)]
         for t in range(0, 28)]
put("spiral", "tube", x=cx, z=cz, points=helix, radius=0.018, color="#9FF3FF", glow=4)
put("crystal-light", "light", x=cx, y=1.5, z=cz, color="#7FE8FF", intensity=2.5, range=6)
put("magic", "particles", preset="magic", x=cx, y=0.4, z=cz, w=1.2, h=0.4, d=1.2, rate=26)
put("burst", "particles", preset="sparkles", x=cx, y=1.5, z=cz, burst=160, size=0.07, trigger=0)
put("ripple", "particles", preset="sparkles", x=-3.4, y=0.05, z=3.2, burst=40, size=0.05, color="#BFEFFF", trigger=0)

# --- the spirit -------------------------------------------------------------------
put("me", "vrm", x=0.85, z=1.6, ry=-25, pose="idle", tappable=True)
put("name", "text", x=0.85, y=1.78, z=1.6, w=240, h=64, size_m=0.16, face_camera=True, text="精霊",
    size=32, align="center", color="#FFFFFF", background="#3B5B8CCC", radius=28)

# --- the sky's things: islets, clouds, stars, moon ---------------------------------
for i, (x, y, z, s) in enumerate([(-11, 2.5, 11, 1.4), (11.5, 4.2, 13, 1.1), (-13, -0.5, -1, 1.0), (13, 1.2, -3.5, 1.3)]):
    put(f"islet{i}", "cone", x=x, y=y, z=z, rx=180, w=round(2.2 * s, 2), h=round(2.6 * s, 2), d=round(2.2 * s, 2),
        color="#5C4636", roughness=1)
    put(f"islet{i}-top", "cylinder", x=x, y=y, z=z, w=round(2.3 * s, 2), h=0.3, d=round(2.3 * s, 2), color="#5D8A47")
    put(f"islet{i}-tree", "cone", x=x, y=round(y + 0.3, 2), z=z, w=round(0.8 * s, 2), h=round(1.4 * s, 2),
        d=round(0.8 * s, 2), color="#356B41")
put("clouds", "scatter", shape="sphere", x=0, y=-4, z=2, dome=70, count=36, seed=11, size=[3, 6],
    stretch=[2.6, 0.55, 1.6], colors=["#FFFFFF", "#F4F1EC"], roughness=1)
put("stars", "scatter", shape="sphere", x=0, y=-2, z=2, dome=90, count=900, seed=5, size=[0.08, 0.26],
    colors=["#FFFFFF", "#CFE0FF", "#FFF1C9"], glow=6, color="#E8F0FF", visible=False)
put("moon", "sphere", x=-34, y=26, z=64, w=5, h=5, d=5, color="#F4F0E2", glow=3, visible=False)
put("fireflies", "particles", preset="fireflies", x=-3.4, y=0.15, z=3.2, w=6, h=1.4, d=5, rate=0)
put("dust", "particles", preset="dust", x=0, y=0.2, z=2, w=12, h=3, d=12, rate=12)

# --- the HUD ----------------------------------------------------------------------
els += [
    {"id": "hint", "type": "text", "anchor": "top-left", "x": 16, "y": 16, "w": "92%", "h": 44,
     "text": "結晶・灯籠・池・精霊を触ってみて", "size": 18, "color": "#FFFFFF", "background": "#00000077",
     "radius": 12, "align": "center"},
    {"id": "back", "type": "button", "anchor": "top-left", "x": 16, "y": 72, "w": 140, "h": 52,
     "label": "戻る", "visible": False, "on": {"press": [{"do": "add", "key": "backs"}]}},
]
for i, (n, label) in enumerate([("dusk", "夕暮れ"), ("night", "夜"), ("morning", "朝")]):
    els.append({"id": f"time-{n}", "type": "button", "anchor": "bottom-left", "x": 16 + i * 136, "y": -16,
                "w": 128, "h": 52, "label": label, "on": {"press": [{"do": "set", "key": "time", "value": n}]}})
els += [
    {"id": "closer", "type": "button", "anchor": "bottom-right", "x": -16, "y": -16, "w": 110, "h": 52,
     "label": "寄る", "on": {"press": [{"do": "add", "key": "closers"}]}},
    {"id": "around", "type": "button", "anchor": "bottom-right", "x": -134, "y": -16, "w": 140, "h": 52,
     "label": "ひと回り", "on": {"press": [{"do": "add", "key": "turns"}]}},
]

SCRIPT = r"""
var HOME = %(home)s;
var LAMPS = %(lamps)s;
var lit = {};
var FAR = { cam_x: 0, cam_y: 9, cam_z: -20, look_x: 0, look_y: 0, look_z: 3, fov: 40 };

// Coming in from far away.
sg.update('isle', FAR);
sg.after(300, function () { sg.update('isle', HOME, 7000); });

// The crystal turns and floats; the rings turn; the islets drift.
function spin(id, base, extra, ms) {
  var a = { at: 0 }, b = { at: 1 };
  for (var k in base) { a[k] = base[k]; b[k] = base[k] + extra[k]; }
  sg.animate(id, { keyframes: [a, b], duration_ms: ms, repeat: -1, easing: 'linear' });
}
spin('crystal', { ry: 0 }, { ry: 360 }, 9000);
spin('crystal-low', { ry: 0 }, { ry: 360 }, 9000);
spin('ring-a', { ry: 0 }, { ry: 360 }, 7000);
spin('ring-b', { ry: 0 }, { ry: -360 }, 11000);
spin('spiral', { ry: 0 }, { ry: 360 }, 6000);
[['islet0', 2.5], ['islet1', 4.2], ['islet2', -0.5], ['islet3', 1.2]].forEach(function (p, i) {
  ['', '-top', '-tree'].forEach(function (s) {
    var y = p[1] + (s === '-top' ? 0 : s === '-tree' ? 0.3 : 0);
    sg.animate(p[0] + s, { keyframes: [{ at: 0, y: y }, { at: 1, y: y + 0.45 }], duration_ms: 4200 + i * 700,
      repeat: -1, alternate: true, easing: 'ease_in_out' });
  });
});

// The time of day.
function lamps(on, ms) {
  LAMPS.forEach(function (n) {
    lit[n] = on;
    sg.update(n, { glow: on ? 5 : 0.3 }, ms);
    sg.update(n + '-light', { intensity: on ? 4 : 0.4 }, ms);
  });
}
var TIMES = {
  dusk: { sky: { sun_elevation: 6, sun_azimuth: 28, exposure: 1.05, warmth: 0.22, fog: 0.007, bloom: 0.12, god_rays: 0.5 },
          fog_color: '#E8B898', night: false, lamps: false, text: '夕暮れ' },
  night: { sky: { sun_elevation: -16, sun_azimuth: 40, exposure: 1.6, warmth: -0.15, fog: 0.008, bloom: 0.25, god_rays: 0 },
           fog_color: '#1A2440', night: true, lamps: true, text: '夜。灯籠がともり、ホタルが飛ぶ' },
  morning: { sky: { sun_elevation: 24, sun_azimuth: -45, exposure: 1.0, warmth: -0.05, fog: 0.004, bloom: 0.08, god_rays: 0.6 },
             fog_color: '#CFE0F0', night: false, lamps: false, text: '朝' },
};
var shown = 'dusk';
function setTime(name) {
  var t = TIMES[name];
  if (!t || name === shown) return;
  shown = name;
  sg.update('isle', t.sky, 6000);
  sg.update('isle', { fog_color: t.fog_color });
  lamps(t.lamps, 4000);
  sg.after(t.night ? 2500 : 0, function () {
    sg.update('stars', { visible: t.night });
    sg.update('moon', { visible: t.night });
  });
  sg.update('fireflies', { rate: t.night ? 10 : 0 }, 3000);
  sg.update('dust', { rate: t.night ? 3 : 12 }, 3000);
  sg.update('crystal-light', { intensity: t.night ? 5 : 2.5 }, 3000);
  sg.update('me', { pose: t.night ? 'sleep' : 'idle' });
  sg.update('hint', { text: t.text });
}

// Touching.
var flares = 0;
function flare() {
  flares += 1;
  sg.update('burst', { trigger: flares });
  ['crystal', 'crystal-low'].forEach(function (id) {
    sg.update(id, { glow: 7 }, 150);
    sg.after(250, function () { sg.update(id, { glow: 2.2 }, 1500); });
  });
  sg.update('crystal-light', { intensity: 14 }, 150);
  sg.after(250, function () { sg.update('crystal-light', { intensity: shown === 'night' ? 5 : 2.5 }, 1500); });
  sg.update('me', { pose: 'cheer', expression: 'happy' });
  sg.speak('わあ、きらきら！', { vrm: 'me', interrupt: true });
  sg.update('hint', { text: '結晶が光った' });
  sg.after(2600, function () { sg.update('me', { pose: shown === 'night' ? 'sleep' : 'idle', expression: 'neutral' }); });
}
sg.on('tap', 'crystal', flare);
sg.on('tap', 'crystal-low', flare);

LAMPS.forEach(function (n) {
  sg.on('tap', n, function () {
    var on = !lit[n];
    lit[n] = on;
    sg.update(n, { glow: on ? 5 : 0.3 }, 400);
    sg.update(n + '-light', { intensity: on ? 4 : 0.4 }, 400);
    sg.update('hint', { text: on ? '灯籠をともした' : '灯籠を消した' });
  });
});

var ripples = 0;
sg.on('tap', 'pond', function (e) {
  ripples += 1;
  var p = e.value || {};
  sg.update('ripple', { x: p.x, y: (p.y || 0) + 0.05, z: p.z, trigger: ripples });
  sg.update('hint', { text: '池にさわった' });
});

sg.on('tap', 'me', function (e) {
  var part = (e.value && e.value.part) || '';
  if (shown === 'night') {
    sg.update('me', { pose: 'wave', expression: 'surprised' });
    sg.speak('むにゃ…あ、夜だね。', { vrm: 'me', interrupt: true });
  } else if (part === 'head') {
    sg.update('me', { pose: 'nod', expression: 'happy' });
    sg.speak('えへへ。', { vrm: 'me', interrupt: true });
  } else {
    sg.update('me', { pose: 'wave', expression: 'happy' });
    sg.speak('ようこそ、わたしの庭へ。', { vrm: 'me', interrupt: true });
  }
  sg.after(2800, function () { sg.update('me', { pose: shown === 'night' ? 'sleep' : 'idle', expression: 'neutral' }); });
});

// The camera: up to the spirit (the rest blurs), and round the island.
var busy = false;
function closer() {
  if (busy) return;
  sg.update('isle', { cam_x: 0.1, cam_y: 1.55, cam_z: -0.3, look_x: 0.85, look_y: 1.35, look_z: 1.6, fov: 38, focus: 2.0 }, 2200);
  sg.update('back', { visible: true });
  sg.update('hint', { text: '精霊に寄った' });
}
function back() {
  sg.update('isle', { focus: 0 });
  sg.update('isle', HOME, 1800);
  sg.update('back', { visible: false });
}
function around() {
  if (busy) return;
  busy = true;
  sg.update('isle', { cam_x: 0, cam_y: 4.5, cam_z: -9.5, look_x: 0, look_y: 0.8, look_z: 2.4, fov: 50, focus: 0 }, 1500);
  sg.after(1500, function () { sg.update('isle', { camera_mode: 'orbit', orbit_speed: 30 }); });
  sg.update('hint', { text: '島をひと回り' });
  sg.after(13500, function () {
    sg.update('isle', { camera_mode: 'fixed' });
    sg.update('isle', HOME, 1500);
    busy = false;
  });
}
var last = { time: 'dusk', closers: 0, turns: 0, backs: 0 };
sg.every(100, function () {
  var t = sg.get('time') || 'dusk';
  if (t !== last.time) { last.time = t; setTime(t); }
  ['closers', 'turns', 'backs'].forEach(function (k) {
    var v = sg.get(k) || 0;
    if (v !== last[k]) { last[k] = v; ({ closers: closer, turns: around, backs: back })[k](); }
  });
});
""" % {"home": json.dumps(HOME), "lamps": json.dumps(LAMPS)}

scene = {
    "name": "spirit-isle",
    "description": "空に浮かぶ精霊の庭（3D）。物理の空と太陽で夕暮れ・夜・朝が移り、池の映り込み・桜の花びら・灯籠の明かり・回る結晶と光の螺旋・星と月・ホタル。結晶・灯籠・池・精霊を触ると反応し、HUD で時間・寄る・ひと回り。モデルなしで動く。",
    "params": {},
    "design": None,
    "background": "#000000",
    "elements": els,
    "state": {"time": "dusk", "closers": 0, "turns": 0, "backs": 0},
    "timelines": {},
    "scripts": {"isle": SCRIPT.strip() + "\n"},
}

with open(os.path.join(HERE, "scenes", "spirit-isle.json"), "w") as f:
    json.dump(scene, f, ensure_ascii=False, indent=1)
print("wrote scenes/spirit-isle.json,", len(els), "elements,",
      sum(e.get("count", 0) for e in els if e["type"] == "scatter"), "scattered copies")
