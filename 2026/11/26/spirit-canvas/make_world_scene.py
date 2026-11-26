"""Writes scenes/world-room.json: the 3D room of world_check.py, made to be
touched, with a HUD of 2D elements over it. Without the model:

- the schedule on the wall: the camera moves up to it, a back button shows
- the back button (HUD): the camera returns, the button hides
- the picture on the wall: the next picture
- the lamp, or the HUD's light button: the lamp and the room's light
- the ball: it bounces
- the body: a reaction by the part touched (head: happy and a nod)
- the HUD's look-around button: the camera goes round once

python3 make_world_scene.py
"""

import json
import os

from world_check import ROOM

HERE = os.path.dirname(os.path.abspath(__file__))
W = "room"
HOME = {"cam_x": 0, "cam_y": 1.7, "cam_z": -4.2, "look_x": 0, "look_y": 1.1, "look_z": 0.5, "fov": 50}
PICTURES = ["jpg/street_scene_1774x887_287kb.jpg", "jpg/objects_1536x1024_358kb.jpg",
            "jpg/miineko1_1254x1254_159kb.jpg"]

elements = []
for e in ROOM:
    e = dict(e)
    if e["id"] == W:
        e.update(HOME)
    if e["id"] == "poster":
        e["tappable"] = True
        e["on"] = {"tap": [
            {"do": "update", "id": W, "transition_ms": 1400, "easing": "ease_in_out",
             "props": {"cam_x": -0.4, "cam_y": 1.75, "cam_z": 1.5, "look_x": -0.4, "look_y": 1.75, "look_z": 2.9,
                       "fov": 45}},
            {"do": "update", "id": "back", "props": {"visible": True}},
            {"do": "update", "id": "hint", "props": {"text": "予定を見ています"}},
        ]}
    if e["id"] == "lamp":
        e["on"] = {"tap": [{"do": "add", "key": "lamp_toggles"}]}
    if e["id"] == "ball":
        e["on"] = {"tap": [{"do": "animate", "id": "ball", "duration_ms": 500, "easing": "ease_out",
                            "keyframes": [{"at": 0, "y": 0}, {"at": 0.5, "y": 0.8}, {"at": 1, "y": 0}]}]}
    if e["id"] == "hello":
        continue  # the HUD has the buttons now
    elements.append(e)

elements += [
    # A picture on the wall, changed by touching it.
    {"id": "frame", "type": "box", "in": W, "x": 2.0, "y": 1.35, "z": 2.93, "w": 0.9, "h": 0.66, "d": 0.03,
     "color": "#6B4F36"},
    {"id": "picture", "type": "image", "in": W, "x": 2.0, "y": 1.4, "z": 2.9, "w": 480, "h": 300, "size_m": 0.56,
     "src": PICTURES[0], "fit": "cover", "tappable": True},
    # The HUD: 2D elements over the world.
    {"id": "hint", "type": "text", "anchor": "top-left", "x": 16, "y": 16, "w": 460, "h": 44,
     "text": "予定・絵・ランプ・ボール・精霊を触ってみて", "size": 18, "color": "#FFFFFF", "background": "#00000088",
     "radius": 12, "align": "center"},
    {"id": "back", "type": "button", "anchor": "bottom-left", "x": 16, "y": -16, "w": 140, "h": 52,
     "label": "戻る", "visible": False,
     "on": {"press": [
         {"do": "update", "id": W, "transition_ms": 1200, "props": HOME},
         {"do": "update", "id": "back", "props": {"visible": False}},
         {"do": "update", "id": "hint", "props": {"text": "予定・絵・ランプ・ボール・精霊を触ってみて"}},
     ]}},
    {"id": "light", "type": "button", "anchor": "bottom-right", "x": -16, "y": -16, "w": 190, "h": 52,
     "label": "明かり", "on": {"press": [{"do": "add", "key": "lamp_toggles"}]}},
    {"id": "around", "type": "button", "anchor": "bottom-right", "x": -222, "y": -16, "w": 160, "h": 52,
     "label": "ひと回り", "on": {"press": [{"do": "add", "key": "turns"}]}},
]

SCRIPT = r"""
var PICTURES = %s;
var picture = 0;

// The picture on the wall: the next one.
sg.on('tap', 'picture', function () {
  picture = (picture + 1) %% PICTURES.length;
  sg.update('picture', { src: PICTURES[picture] });
  sg.update('hint', { text: '絵を替えました（' + (picture + 1) + ' / ' + PICTURES.length + '）' });
});

// The lamp (touched, or the HUD's button): on and off, with the room.
function lamp() {
  var on = (sg.get('lamp_toggles') || 0) %% 2 === 0;
  sg.update('lamp', { glow: on, color: on ? '#FFD98A' : '#8A8170' });
  sg.update('room', { light: on ? 3 : 0.8, sky: on ? '#CFE3F2' : '#2A3550' });
  sg.update('light', { label: on ? '明かり' : '明かりをつける' });
}

// Once round, back where it was.
var turning = false;
function around() {
  if (turning || !sg.get('turns')) return;
  turning = true;
  sg.update('room', { camera_mode: 'orbit', orbit_speed: 40 });
  sg.update('hint', { text: 'ぐるっと見回しています' });
  sg.after(9000, function () {
    sg.update('room', { camera_mode: 'fixed' });
    sg.update('hint', { text: '予定・絵・ランプ・ボール・精霊を触ってみて' });
    turning = false;
  });
}
var lastLamp = -1, lastTurns = 0;
sg.every(100, function () {
  var l = sg.get('lamp_toggles') || 0;
  if (l !== lastLamp) { lastLamp = l; lamp(); }
  var t = sg.get('turns') || 0;
  if (t !== lastTurns) { lastTurns = t; around(); }
});

// The body: by the part touched.
sg.on('tap', 'me', function (e) {
  var part = (e.value && e.value.part) || '';
  if (part === 'head') {
    sg.update('me', { pose: 'nod', expression: 'happy' });
    sg.speak('えへへ、なでてくれるの？', { vrm: 'me', interrupt: true });
  } else {
    sg.update('me', { pose: 'wave', expression: 'happy' });
    sg.speak('なあに？', { vrm: 'me', interrupt: true });
  }
  var names = { head: '頭', neck: '首', chest: '胸', upperChest: '胸', spine: 'おなか', hips: '腰' };
  var name = names[part] || (part.indexOf('Arm') >= 0 || part.indexOf('Hand') >= 0 ? '腕' :
      part.indexOf('Leg') >= 0 || part.indexOf('Foot') >= 0 ? '足' : '体');
  sg.update('hint', { text: '精霊の' + name + 'に触れました' });
  sg.after(2500, function () { sg.update('me', { pose: 'idle', expression: 'neutral' }); });
});
""" % json.dumps(PICTURES)

scene = {
    "name": "world-room",
    "description": "3D の部屋（形・板・精霊の体）と、その上の HUD。壁の予定を触るとカメラが寄り、HUD の戻るで戻る。絵・ランプ・ボール・精霊も触ると反応し、HUD の明かり・ひと回りで部屋が変わる。モデルなしで動く。",
    "params": {},
    "background": "#202020",
    "elements": elements,
    "state": {"lamp_toggles": 0, "turns": 0},
    "timelines": {},
    "scripts": {"room-actions": SCRIPT.strip() + "\n"},
}

with open(os.path.join(HERE, "scenes", "world-room.json"), "w") as f:
    json.dump(scene, f, ensure_ascii=False, indent=1)
print("wrote scenes/world-room.json")
