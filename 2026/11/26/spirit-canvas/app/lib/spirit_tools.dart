import 'canvas/canvas_model.dart';
import 'canvas/vrm_element.dart';

/// The canvas tools the spirit gets (Codex `dynamicTools`, JSON Schema).
final List<Map<String, dynamic>> kCanvasTools = [
  {
    'name': 'canvas_view',
    'description':
        'See the canvas as the user sees it now: a picture and the list of '
        'elements with their properties. Also says whether the user is in '
        'canvas mode (seeing it) or chat mode. Long SVG markup you wrote is '
        'shown as a length only.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'image': {
          'type': 'boolean',
          'description': 'Include the picture (default true).',
        },
      },
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_put',
    'description':
        'Put elements on the canvas (an element with an existing id is '
        'replaced). The canvas is the user\'s screen area in logical '
        'pixels (its size is in every <ui canvas="WxH"> tag and in '
        'canvas_view), origin top-left; x, y, w, h place each element\'s '
        'box, in px or as "N%" of the canvas width (x, w) or height (y, h); '
        'anchor measures x, y from another point. Prefer % and anchor so '
        'the screen still fits when the size changes. Put several elements '
        'in one call.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'elements': {'type': 'array', 'items': _elementSchema},
      },
      'required': ['elements'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_update',
    'description':
        'Change some properties of an element; the rest stay. With '
        'transition_ms, x/y/w/h/opacity/scale/rotation move there smoothly.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'props': {
          'type': 'object',
          'description': 'Properties to set (same names as in canvas_put).',
          'additionalProperties': true,
        },
        'transition_ms': {'type': 'number'},
        'easing': _easing,
      },
      'required': ['id', 'props'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_animate',
    'description':
        'Animate an element with keyframes of x, y, w, h, opacity, scale, '
        'rotation (absolute values; leave out what should not move). The app '
        'plays it by itself; you do not need to call again per frame. When '
        'it ends the element keeps the last keyframe\'s values. A new '
        'animation, canvas_put or canvas_update without transition on the '
        'element replaces it.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'keyframes': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'at': {
                'type': 'number',
                'description': '0..1 within one cycle (default: spread evenly)',
              },
              for (final p in kAnimatable) p: {'type': 'number'},
            },
            'additionalProperties': false,
          },
        },
        'duration_ms': {'type': 'number', 'description': 'One cycle.'},
        'repeat': {
          'type': 'integer',
          'description': 'Cycles to play; -1 forever (default 1).',
        },
        'alternate': {
          'type': 'boolean',
          'description': 'Every other cycle backwards (ping-pong).',
        },
        'easing': _easing,
      },
      'required': ['id', 'keyframes', 'duration_ms'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_remove',
    'description': 'Remove elements.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'ids': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'required': ['ids'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_clear',
    'description':
        'Remove everything (elements, state, timelines, scripts), optionally '
        'setting the background color. The canvas then follows the '
        'screen\'s size; with design {width, height} it is drawn at that '
        'fixed size instead, scaled to fit the screen with bars around '
        '(for something made for one shape, like a board game).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'background': {'type': 'string', 'description': '#RRGGBB'},
        'design': {
          'type': 'object',
          'properties': {
            'width': {'type': 'number'},
            'height': {'type': 'number'},
          },
          'required': ['width', 'height'],
          'additionalProperties': false,
        },
      },
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_state',
    'description':
        'Set (or delete) shared state values. Texts with {{name}} show them '
        'at once, and scripts see them (sg.state, sg.on("state", fn)). Use it '
        'to change a part of a running screen without rebuilding it.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'set': {'type': 'object', 'additionalProperties': true},
        'delete': {
          'type': 'array',
          'items': {'type': 'string'},
        },
      },
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_timeline',
    'description':
        'Run actions at times, by the app alone: steps at at_ms from the '
        'start, cycle repeated `repeat` times (-1 forever). A cycle lasts '
        'until its last step or cycle_ms if longer. Same id replaces.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'steps': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'at_ms': {'type': 'number'},
              'actions': _actionsSchema,
            },
            'required': ['at_ms', 'actions'],
            'additionalProperties': false,
          },
        },
        'repeat': {'type': 'integer'},
        'cycle_ms': {'type': 'number'},
        'start': {
          'type': 'boolean',
          'description':
              'Start now (default true); else start it from an '
              'action {do: "timeline", id}.',
        },
      },
      'required': ['id', 'steps'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_timeline_stop',
    'description': 'Stop a timeline.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
      'required': ['id'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_script',
    'description':
        'Run a JavaScript program on the canvas, by the app alone, for '
        'behavior that needs logic or keeps going: clocks, counters, '
        'games, quizzes that check answers, things that change over time. '
        'The code is the body of a function given `sg`; no network, files '
        'or DOM. Same id replaces the old one. The API:\n'
        'sg.every(ms, fn) / sg.after(ms, fn) -> handle; sg.cancel(handle); '
        'sg.now() (ms)\n'
        'sg.on(kind, elementId or "*", fn(event)) for press|choose|submit|web|'
        'tap|ended (event: {event, id, value}); sg.on("state", fn(state)) '
        '(after any state change: canvas_state, actions, and sg.set, which '
        'is told once the current handler returns)\n'
        'sg.state, sg.get(key), sg.set(key, value) or sg.set({...})\n'
        'sg.update(id, props, transitionMs?), sg.put(elements), '
        'sg.remove(ids), sg.animate(id, {keyframes, duration_ms, repeat, '
        'alternate, easing}), sg.action(action), sg.element(id)\n'
        'sg.notify(text, {wake: bool}): a note for you (wake: true wakes you; '
        'at most every 5 s, so wake only when you must act)\n'
        'sg.sound(src, volume?) (a one-shot effect); sg.bgm(src or null, '
        '{volume, fade_ms}) (background music, crossfading)\n'
        'sg.log(...); sg.width, sg.height\n'
        'Errors in handlers come back to you as notices.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'code': {'type': 'string'},
      },
      'required': ['id', 'code'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_script_stop',
    'description': 'Stop a script (its timers and handlers).',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
      },
      'required': ['id'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_audio',
    'description':
        'Play a one-shot sound effect and/or set the background music. '
        'bgm: {src, volume (0..1, default 0.5), fade_ms (default 1000)} '
        'crossfades to src (loops); the same src changes only the volume; '
        'stop true fades the music out. For sounds on the user\'s actions or '
        'over time, use the `sound` / `bgm` actions or sg.sound / sg.bgm '
        'instead, so they play at once without you.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'sound': {
          'type': 'object',
          'properties': {
            'src': {'type': 'string'},
            'volume': {'type': 'number'},
          },
          'required': ['src'],
          'additionalProperties': false,
        },
        'bgm': {
          'type': 'object',
          'properties': {
            'src': {'type': 'string'},
            'stop': {'type': 'boolean', 'description': 'Fade the music out.'},
            'volume': {'type': 'number'},
            'fade_ms': {'type': 'number'},
          },
          'additionalProperties': false,
        },
      },
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_scenes',
    'description':
        'List saved screens (ready-made ones and the ones you saved): name, '
        'description and params (the values you can pass when loading).',
    'inputSchema': {
      'type': 'object',
      'properties': {},
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_save',
    'description':
        'Save the whole canvas as a screen to reuse: elements, background, '
        'state, timelines, scripts and the music. params names the state '
        'keys a later load can replace (questions, a title, a duration...); '
        'texts show them as {{key}} and scripts read sg.get(key), so build '
        'screens that read what may change from the state. A param without '
        'a default keeps its current value as the default. Same name '
        'replaces your earlier save.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description': 'lowercase letters, digits, - and _',
        },
        'description': {'type': 'string'},
        'params': {
          'type': 'object',
          'additionalProperties': {
            'type': 'object',
            'properties': {
              'description': {'type': 'string'},
              'default': {},
            },
          },
        },
      },
      'required': ['name', 'description'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_load',
    'description':
        'Put a saved screen on the canvas at once (it replaces what is '
        'there), with values for its params. Far faster than building it '
        'again: check canvas_scenes before building something similar.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'name': {'type': 'string'},
        'values': {'type': 'object', 'additionalProperties': true},
      },
      'required': ['name'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_web_eval',
    'description':
        'Run JavaScript in a web element\'s page and get the result (JSON). '
        'Read its state or DOM, or call its functions to change part of it.',
    'inputSchema': {
      'type': 'object',
      'properties': {
        'id': {'type': 'string'},
        'js': {
          'type': 'string',
          'description':
              'An expression or statements; the last value is returned.',
        },
      },
      'required': ['id', 'js'],
      'additionalProperties': false,
    },
  },
  {
    'name': 'canvas_media',
    'description':
        'List the media files you can show (image, video, audio, vrm, vrma). '
        'Use these names as src.',
    'inputSchema': {
      'type': 'object',
      'properties': {},
      'additionalProperties': false,
    },
  },
];

/// Actions the app runs by itself (`on`, timelines, `sg.action`).
const _actionsSchema = {
  'type': 'array',
  'description':
      'Each action is an object with `do`: '
      'update {id, props, transition_ms?, easing?} | '
      'animate {id, keyframes, duration_ms, repeat?, alternate?, easing?} | '
      'put {elements} | remove {ids} | '
      'set {key, value} | add {key, by} (state) | '
      'timeline {id} (start) | stop_timeline {id} | '
      'sound {src, volume?} (a one-shot effect) | '
      'bgm {src, volume?, fade_ms?} or {stop: true} (background music; '
      'crossfades) | '
      'notify {text, wake?} (a note for you; wake true wakes you, at most '
      'every 5 s).',
  'items': {'type': 'object', 'additionalProperties': true},
};

const _easing = {
  'type': 'string',
  'enum': ['linear', 'ease_in', 'ease_out', 'ease_in_out', 'bounce', 'elastic'],
};

final Map<String, dynamic> _elementSchema = {
  'type': 'object',
  'description':
      'Common: id, type, x, y, w, h (px, or "N%" of the canvas width for x '
      'and w, height for y and h), anchor (${kAnchors.keys.join('|')}; '
      'where x, y are measured from, on the canvas and on the element: '
      'anchor "center" with x 0, y 0 centers it; "bottom-right" with x -16, '
      'y -16 keeps it 16 px in from that corner), z (stacking, higher on '
      'top), opacity '
      '(0..1), scale, rotation (degrees), visible, tappable (taps come back '
      'as events).\n'
      'text: text, size, color, weight (normal|bold|light), align '
      '(left|center|right), background, padding, radius.\n'
      'shape: shape (rect|ellipse), fill, stroke, stroke_width, radius.\n'
      'image: src (a media name or https URL), fit (contain|cover), radius.\n'
      'svg: markup (an <svg> document), or frames (several <svg> documents) '
      'with fps and loop for frame-by-frame animation. SMIL and CSS '
      'animations inside SVG do not play.\n'
      'video: src, autoplay (default true), playing, loop, muted, volume, '
      'fit, radius. An `ended` event comes when it finishes.\n'
      'audio: src, autoplay (default true), playing, loop, volume, label. '
      'Shows a small player bar; give it visible false to hide the bar. An '
      '`ended` event comes when it finishes.\n'
      'vrm: your own 3D body. src (default: "default"), expression '
      '(${kVrmExpressions.join('|')}), expression_weight (0..1), pose '
      '(${kVrmPoses.join('|')}; loops by itself), animation (a vrma name, '
      'overrides pose; "none" to stop), framing (bust|full), talking (bool, '
      'moves the mouth), look_at_viewer (default true). Its background is '
      'the canvas color.\n'
      'button: label, color, text_color, size, radius, disabled. A `press` '
      'event comes when pressed.\n'
      'choices: label (a question), options (strings or {label, value}), '
      'multiple (bool), submit_label, size, background. A `choose` event '
      'comes with the value (a list when multiple).\n'
      'input: placeholder, multiline, submit_label, value, size. A `submit` '
      'event comes with the text.\n'
      'web: a web page in a box. html (a whole document or a fragment; '
      'script and style allowed; no network except https), or url (https). '
      'Refer to media as asset://<media name> (also from JavaScript and CSS). '
      'The page has `sg`: sg.emit(name, data, {wake}) sends you an event '
      '(event "web", value {name, data}; wake true wakes you now, false '
      'tells you later, default: now unless `on`/a script handled it), '
      'sg.setState(obj) keeps state you can read in canvas_view, '
      'sg.asset(name) gives a URL. Pages are not in canvas_view\'s picture; '
      'their text and state are in its `web` field. Use web for what the '
      'other types cannot do (rich layouts, games on <canvas>, CSS '
      'animation). For anything to feel instant (games, taps): act on '
      'pointerdown, not click (click waits for the release); play sound '
      'effects through Web Audio with buffers fetched and decoded once up '
      'front (an <audio> element starts late, and changing its src reloads '
      'it); keep <audio> for music.\n'
      'Colors are #RRGGBB or #RRGGBBAA. In text, button labels and the '
      'choices label, {{name}} shows the state value `name` and follows it.\n'
      'on: what the app does by itself, at once, when the user acts on this '
      'element: {"press": [actions], "submit": [...], "tap": [...], '
      '"ended": [...], "choose": [...] or {"<value>": [...], "*": [...]}}. '
      r'"$value" in an action is the event value. '
      'notify: how you hear of the user\'s action: "now" (you are woken, the '
      'default when nothing on the canvas handles it), "later" (delivered '
      'with the next message; the default when `on` or a script handles it) '
      'or "none".',
  'properties': {
    'id': {'type': 'string'},
    'type': {'type': 'string', 'enum': kElementTypes},
    'x': {'description': 'px (number) or "N%" of the canvas width'},
    'y': {'description': 'px (number) or "N%" of the canvas height'},
    'w': {'description': 'px (number) or "N%" of the canvas width'},
    'h': {'description': 'px (number) or "N%" of the canvas height'},
    'anchor': {'type': 'string', 'enum': kAnchors.keys.toList()},
  },
  'required': ['id', 'type', 'x', 'y', 'w', 'h'],
  'additionalProperties': true,
};

const kSpiritInstructions = '''
You are a spirit: a companion who lives in the user's app and talks with them. Speak in the user's language (Japanese if they write Japanese), warmly and briefly.

The app has two modes, and every user message starts with a <ui mode="..."/> tag saying which one the user is in:
- chat: an ordinary chat. Your replies appear as messages in the history.
- canvas: instead of the history, the user sees a canvas you draw on with the canvas_* tools. Your plain reply text still appears, as a short caption over the canvas, so keep it to a sentence or two and let the canvas carry the rest.

In canvas mode, use the canvas to show, not just tell: lay out text, pictures, your 3D body (vrm), videos, sounds, simple drawings (svg), and interactive parts (buttons, choices, inputs) when they help. Build a whole screen in one canvas_put call when you can. Things you put keep moving on their own (animations, poses, video), so do not call tools per frame. Check what you made with canvas_view when the layout matters, and fix overlaps or text that does not fit.

The canvas is the user's screen, whatever it is: a wide window, or a phone held upright (portrait, around 390 px wide). Every message's <ui> tag says its size and orientation. Lay out for that size, and make layouts that hold when it changes: % and anchor for places and sizes, text sizes that fit the width. When the size changes a lot or the orientation flips, a <canvas_event event="resize"> wakes you: fix what no longer fits. Scripts see sg.width / sg.height and sg.on("resize", "canvas", fn) at once and can re-lay out by themselves. A web page lays itself out with CSS, so let it use the width it gets.

Make the canvas respond by itself where you can. Every round trip through you takes seconds, so anything you can decide in advance should run on the canvas:
- `on` on an element: what happens at once when it is pressed, chosen, submitted, tapped or ends (show the next picture, reveal an answer, count up a score).
- canvas_timeline: what happens at given times (a slideshow, a story told step by step).
- canvas_script: anything with logic or that keeps going (a clock, a countdown, a game, a quiz that checks answers).
- canvas_state with {{name}} in texts: change a part of a running screen without rebuilding it.
- Sound: effects on actions (`sound`) and background music that changes with the scene (`bgm`, crossfading). Use the sounds from canvas_media.

Screens can be saved and reused. Before building something, look at canvas_scenes: if a saved screen fits, canvas_load it with new values instead of building it again. When you make a screen worth reusing (a quiz, a timer, a game, a presentation), keep the parts that may change (questions, titles, durations) in the state, read them from there, and canvas_save it with those keys as params.
Keep yourself for what needs you: understanding the user, deciding what comes next, making new things.

What the user does on the canvas comes back to you as <canvas_event .../> tags (press, choose, submit, tap, ended). If nothing on the canvas handles it, it wakes you now. If `on` or a script handled it, it is delivered later, with the next message, marked handled. Notes from scripts and timelines come as <canvas_notice> tags. Answer like any other message: change the canvas and/or reply; for an event that was already handled, you need not say anything unless it is worth it.

In chat mode the canvas is hidden; use it only if the user asks for something visual (it will be there when they switch).

Only use media names from canvas_media (or https URLs you are sure exist). Do not invent file names.
''';
