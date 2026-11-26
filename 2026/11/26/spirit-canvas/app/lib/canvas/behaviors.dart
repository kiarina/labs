import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' show Size;

import 'package:flutter/foundation.dart';
import 'package:flutter_js/flutter_js.dart';

import 'canvas_model.dart';
import 'sound.dart';
import 'speech.dart';
import 'web_host.dart';

/// Something for the spirit that does not wake it: delivered with the next
/// message that goes to it (the user's, an event's, or a wake).
class CanvasNotice {
  CanvasNotice(this.line);

  final String line;
}

/// What runs on the canvas without the spirit: the actions declared on
/// elements (`on`), timelines, and scripts; the shared state; and the
/// notices they leave for the spirit.
///
/// [wake] sends lines to the spirit now (a new turn, or steered into the
/// running one). Everything else waits in [notices] for the next message.
class CanvasBehaviors {
  CanvasBehaviors(this.canvas, {required this.wake, this.sounds, this.speech}) {
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
  }

  final CanvasController canvas;
  final void Function(List<String> lines) wake;

  /// Effects and music; null in tests.
  final SoundBoard? sounds;

  /// The OS voice saying lines; null in tests.
  final SpeechPlayer? speech;

  /// What defined the running timelines and scripts, for saving a scene.
  final timelineDefs = <String, Map<String, dynamic>>{};
  final scriptSources = <String, String>{};

  late final Timer _ticker;
  final notices = <CanvasNotice>[];
  int droppedNotices = 0;
  final timelines = <String, _Timeline>{};
  final scriptErrors = <String, String>{};

  /// Wakes from scripts and actions are at least this far apart; the ones in
  /// between wait and go together.
  static const wakeInterval = Duration(seconds: 5);
  DateTime _lastWake = DateTime.fromMillisecondsSinceEpoch(0);
  final _wakeLines = <String>[];
  Timer? _wakeTimer;

  // --- notices and wakes -------------------------------------------------

  void notice(String line) {
    notices.add(CanvasNotice(line));
    if (notices.length > 50) {
      notices.removeAt(0);
      droppedNotices++;
    }
  }

  /// The waiting notices as lines, emptied.
  List<String> takeNotices() {
    final lines = [
      if (droppedNotices > 0)
        '<canvas_notice dropped="$droppedNotices" text="older notices were dropped"/>',
      for (final n in notices) n.line,
    ];
    notices.clear();
    droppedNotices = 0;
    return lines;
  }

  /// A wake from a script or an action, rate limited ([wakeInterval]).
  void requestWake(String line) {
    _wakeLines.add(line);
    final since = DateTime.now().difference(_lastWake);
    _wakeTimer?.cancel();
    _wakeTimer = Timer(
      since >= wakeInterval ? Duration.zero : wakeInterval - since,
      _flushWake,
    );
  }

  void _flushWake() {
    if (_wakeLines.isEmpty) return;
    _lastWake = DateTime.now();
    final lines = [..._wakeLines];
    _wakeLines.clear();
    wake(lines);
  }

  // --- events from the user ------------------------------------------------

  /// Routes a user's event: the element's own actions run first, then the
  /// scripts' handlers. Returns how the spirit hears of it: `now` (wake it),
  /// `later` (a notice) or `none`.
  String handleEvent(CanvasEvent e) {
    final el = canvas.elements[e.id];
    var handled = false;
    final on = el?.props['on'];
    if (on is Map) {
      final actions = _actionsFor(on[e.kind], e.value);
      if (actions.isNotEmpty) {
        handled = true;
        runActions(actions, from: 'element:${e.id}', event: e);
      }
    }
    if (_scripts.handleEvent(e)) handled = true;
    final declared = el?.str('notify');
    return declared ?? (handled ? 'later' : 'now');
  }

  /// `on.press` may be a list of actions, or (for `choose`) a map from the
  /// chosen value to a list, with `*` for any.
  List<Map<String, dynamic>> _actionsFor(Object? spec, Object? value) {
    if (spec is List) return _maps(spec);
    if (spec is Map) {
      final key = value is List ? null : '$value';
      return _maps(spec[key] ?? spec['*']);
    }
    return const [];
  }

  static List<Map<String, dynamic>> _maps(Object? v) => [
    for (final a in (v as List? ?? const []))
      if (a is Map) a.cast<String, dynamic>(),
  ];

  // --- actions ---------------------------------------------------------------

  /// Runs declared actions. `$value` in a string is the event's value.
  /// Returns problems (unknown actions, missing elements).
  List<String> runActions(
    List<Map<String, dynamic>> actions, {
    required String from,
    CanvasEvent? event,
  }) {
    final problems = <String>[];
    for (final raw in actions) {
      final a = _substitute(raw, event) as Map<String, dynamic>;
      final err = _runAction(a, from: from);
      if (err != null) problems.add(err);
    }
    if (problems.isNotEmpty) {
      notice(
        '<canvas_notice from="${_attr(from)}" problem="${_attr(problems.join('; '))}"/>',
      );
    }
    return problems;
  }

  Object? _substitute(Object? v, CanvasEvent? e) {
    if (v is String) {
      if (v == r'$value') return e?.value;
      return v.replaceAll(r'$value', '${e?.value ?? ''}');
    }
    if (v is List) return [for (final x in v) _substitute(x, e)];
    if (v is Map) {
      return {
        for (final MapEntry(:key, :value) in v.entries)
          '$key': _substitute(value, e),
      };
    }
    return v;
  }

  String? _runAction(Map<String, dynamic> a, {required String from}) {
    switch (a['do']) {
      case 'update':
        return canvas.update(
          '${a['id']}',
          (a['props'] as Map? ?? const {}).cast<String, dynamic>(),
          transitionMs: (a['transition_ms'] as num?)?.toDouble(),
          easing: a['easing'] as String? ?? 'ease_in_out',
        );
      case 'animate':
        return canvas.animate(
          '${a['id']}',
          keyframes: _maps(a['keyframes']),
          durationMs: (a['duration_ms'] as num?)?.toDouble() ?? 1000,
          repeat: (a['repeat'] as num?)?.toInt() ?? 1,
          alternate: a['alternate'] as bool? ?? false,
          easing: a['easing'] as String? ?? 'ease_in_out',
        );
      case 'put':
        final p = canvas.put(_maps(a['elements']));
        return p.isEmpty ? null : p.join('; ');
      case 'remove':
        final missing = canvas.remove([
          for (final id in (a['ids'] as List? ?? const [])) '$id',
        ]);
        return missing.isEmpty ? null : 'not found: ${missing.join(', ')}';
      case 'set':
        canvas.setState({'${a['key']}': a['value']});
        _scripts.pushState();
        return null;
      case 'add':
        final key = '${a['key']}';
        final now = (canvas.state[key] as num?) ?? 0;
        canvas.setState({key: now + ((a['by'] as num?) ?? 1)});
        _scripts.pushState();
        return null;
      case 'timeline':
        return startTimeline('${a['id']}');
      case 'stop_timeline':
        stopTimeline('${a['id']}');
        return null;
      case 'sound':
        final src = a['src'] as String?;
        if (src == null) return 'sound without src';
        sounds?.play(src, volume: (a['volume'] as num?)?.toDouble() ?? 1).then((
          err,
        ) {
          if (err != null) {
            notice(
              '<canvas_notice from="${_attr(from)}" problem="${_attr(err)}"/>',
            );
          }
        });
        return null;
      case 'bgm':
        sounds
            ?.bgm(
              a['stop'] == true ? null : a['src'] as String?,
              volume: (a['volume'] as num?)?.toDouble() ?? 0.5,
              fadeMs: (a['fade_ms'] as num?)?.toDouble() ?? 1000,
            )
            .then((err) {
              if (err != null) {
                notice(
                  '<canvas_notice from="${_attr(from)}" problem="${_attr(err)}"/>',
                );
              }
            });
        return null;
      case 'speak':
        final text = a['text'] as String?;
        if (text == null || text.isEmpty) return 'speak without text';
        if (speech == null) return 'no speech here';
        speech!.say(
          SpeechLine(
            text: text,
            id: a['id'] as String?,
            vrm: a['vrm'] as String?,
            caption: a['caption'] as String?,
            rate: (a['rate'] as num?)?.toDouble() ?? 1.0,
            language: a['language'] as String? ?? 'ja-JP',
          ),
          interrupt: a['interrupt'] == true,
        );
        return null;
      case 'stop_speaking':
        speech?.stop();
        return null;
      case 'web':
        // Run JavaScript in a web element's page (e.g. go to a slide).
        final id = a['id'] as String?;
        final js = a['js'] as String?;
        if (id == null || js == null) return 'web needs id and js';
        if (canvas.elements[id]?.type != 'web') return 'no web element "$id"';
        unawaited(
          WebHost.instance
              .eval(id, js)
              .then<void>(
                (_) {},
                onError: (Object e) => notice(
                  '<canvas_notice from="${_attr(from)}" problem="${_attr('web "$id": $e')}"/>',
                ),
              ),
        );
        return null;
      case 'notify':
        final line =
            '<canvas_notice from="${_attr(from)}">${_text('${a['text'] ?? ''}')}</canvas_notice>';
        if (a['wake'] == true) {
          requestWake(line);
        } else {
          notice(line);
        }
        return null;
    }
    return 'unknown action "${a['do']}"';
  }

  // --- timelines ---------------------------------------------------------------

  /// Defines a timeline: steps of actions at times (ms from its start),
  /// played [repeat] times (-1 forever). Starts it unless [start] is false.
  String? defineTimeline(
    String id,
    List<Map<String, dynamic>> steps, {
    int repeat = 1,
    double? cycleMs,
    bool start = true,
  }) {
    if (steps.isEmpty) return 'no steps';
    final sorted = [...steps]
      ..sort(
        (a, b) =>
            ((a['at_ms'] as num?) ?? 0).compareTo((b['at_ms'] as num?) ?? 0),
      );
    final last = ((sorted.last['at_ms'] as num?) ?? 0).toDouble();
    // A cycle lasts until its last step, or cycle_ms if longer; at least 50 ms.
    final length = math.max(50.0, math.max(last, cycleMs ?? 0));
    timelineDefs[id] = {
      'steps': steps,
      'repeat': repeat,
      'cycle_ms': ?cycleMs,
      'start': start,
    };
    timelines[id] = _Timeline(sorted, repeat == 0 ? 1 : repeat, length);
    if (start) return startTimeline(id);
    return null;
  }

  bool stopTimeline(String id) {
    final t = timelines[id];
    t?.running = false;
    return t != null;
  }

  /// Stops and forgets every timeline and script (the canvas was cleared).
  void reset() {
    timelines.clear();
    timelineDefs.clear();
    scriptSources.clear();
    for (final id in scriptIds) {
      stopScript(id);
    }
    scriptErrors.clear();
  }

  String? startTimeline(String id) {
    final t = timelines[id];
    if (t == null) return 'no timeline "$id"';
    t
      ..running = true
      ..startedAt = DateTime.now()
      ..cycle = 0
      ..next = 0;
    return null;
  }

  void _tick() {
    final now = DateTime.now();
    for (final MapEntry(key: id, value: t) in timelines.entries) {
      if (!t.running) continue;
      final local =
          now.difference(t.startedAt).inMicroseconds / 1000 -
          t.cycle * t.cycleMs;
      while (t.next < t.steps.length &&
          ((t.steps[t.next]['at_ms'] as num?) ?? 0) <= local) {
        runActions(_maps(t.steps[t.next]['actions']), from: 'timeline:$id');
        t.next++;
      }
      if (t.next >= t.steps.length && local >= t.cycleMs) {
        t
          ..cycle += 1
          ..next = 0;
        if (t.repeat >= 0 && t.cycle >= t.repeat) t.running = false;
      }
    }
    _scripts.tick();
  }

  // --- scripts -------------------------------------------------------------------

  late final _scripts = _ScriptHost(this);

  /// Loads (or replaces) a script. Returns an error message, if it failed.
  String? loadScript(String id, String code) {
    final err = _scripts.load(id, code);
    if (err == null) scriptSources[id] = code;
    return err;
  }

  bool stopScript(String id) {
    scriptSources.remove(id);
    return _scripts.stop(id);
  }

  List<String> get scriptIds => _scripts.ids.toList();

  void stateChangedBySpirit() => _scripts.pushState();

  /// The canvas changed size: scripts see sg.width / sg.height change and get
  /// a `resize` event.
  void resized(Size size) => _scripts.resized(size);

  Map<String, dynamic> describe() => {
    'state': canvas.state,
    'timelines': {
      for (final MapEntry(:key, :value) in timelines.entries)
        key: {
          'running': value.running,
          'cycle': value.cycle,
          'steps': value.steps.length,
          'cycle_ms': value.cycleMs,
        },
    },
    'scripts': scriptIds,
    'bgm': ?sounds?.bgmState,
    if (scriptErrors.isNotEmpty) 'script_errors': scriptErrors,
    'waiting_notices': notices.length,
  };

  void dispose() {
    _ticker.cancel();
    _wakeTimer?.cancel();
    _scripts.dispose();
  }
}

String _attr(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;');
String _text(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;');

class _Timeline {
  _Timeline(this.steps, this.repeat, this.cycleMs);

  final List<Map<String, dynamic>> steps;
  final int repeat;
  final double cycleMs;
  bool running = false;
  DateTime startedAt = DateTime.now();
  int cycle = 0;
  int next = 0;
}

/// The scripts' JavaScript: one JavaScriptCore (macOS/iOS) or QuickJS
/// context for all of them, without fetch or XHR. Each script runs as a
/// function with its own `sg` (see [_prelude]); the host drives timers
/// (`__sg.tick`) and events (`__sg.event`), and the script talks back through
/// `sendMessage('sg', ...)`, answered synchronously.
class _ScriptHost {
  _ScriptHost(this.owner);

  final CanvasBehaviors owner;
  JavascriptRuntime? _js;
  final ids = <String>{};
  final _clock = Stopwatch()..start();
  final _errors = <String, int>{};

  CanvasController get canvas => owner.canvas;

  JavascriptRuntime get js {
    final existing = _js;
    if (existing != null) return existing;
    final rt = getJavascriptRuntime(xhr: false);
    rt.onMessage('sg', _onMessage);
    // QuickJS (Windows, Android) may not know the time zone and give UTC
    // for local times: tell it the offset (minutes east of UTC).
    rt.evaluate(
      'var __SG_TZ_OFFSET_MIN = ${DateTime.now().timeZoneOffset.inMinutes};',
    );
    final r = rt.evaluate(_prelude);
    if (r.isError) debugPrint('[script] prelude failed: ${r.stringResult}');
    _js = rt;
    resized(owner.canvas.size);
    pushState();
    return rt;
  }

  String? load(String id, String code) {
    stop(id);
    _errors.remove(id);
    final r = js.evaluate(
      '__sg.load(${jsonEncode(id)}, function(sg) {\n$code\n})',
    );
    if (r.isError || r.stringResult.startsWith('error:')) {
      final msg = r.stringResult;
      owner.scriptErrors[id] = msg;
      return msg;
    }
    owner.scriptErrors.remove(id);
    ids.add(id);
    return null;
  }

  bool stop(String id) {
    if (_js == null || !ids.remove(id)) return false;
    js.evaluate('__sg.stop(${jsonEncode(id)})');
    return true;
  }

  void tick() {
    if (ids.isEmpty || _js == null) return;
    final r = js.evaluate('__sg.tick(${_clock.elapsedMilliseconds})');
    if (r.isError) debugPrint('[script] tick: ${r.stringResult}');
  }

  /// True if any script handled it.
  bool handleEvent(CanvasEvent e) {
    if (ids.isEmpty) return false;
    final r = js.evaluate('__sg.event(${jsonEncode(e.toJson())})');
    return r.stringResult == 'true';
  }

  void resized(Size size) {
    if (_js == null) return;
    js.evaluate('__sg.width = ${size.width}; __sg.height = ${size.height}');
    if (ids.isNotEmpty) {
      js.evaluate(
        '__sg.event(${jsonEncode({
          'event': 'resize',
          'id': 'canvas',
          'value': {'width': size.width, 'height': size.height},
        })})',
      );
    }
  }

  void pushState() {
    if (_js == null) return;
    js.evaluate('__sg.state = ${jsonEncode(canvas.state)}; __sg.onState()');
  }

  /// A command from a script: `[script id, command, ...args]`.
  Object? _onMessage(dynamic args) {
    final list = args as List;
    final from = 'script:${list[0]}';
    final cmd = list[1] as String;
    Map<String, dynamic> m(Object? o) =>
        (o as Map? ?? const {}).cast<String, dynamic>();
    switch (cmd) {
      case 'set':
        canvas.setState(m(list[2]));
        return true;
      case 'action':
        return owner.runActions([m(list[2])], from: from).isEmpty;
      case 'notify':
        final opts = m(list[3]);
        final line =
            '<canvas_notice from="${_attr(from)}">${_text('${list[2]}')}</canvas_notice>';
        if (opts['wake'] == true) {
          owner.requestWake(line);
        } else {
          owner.notice(line);
        }
        return true;
      case 'error':
        // A script that keeps failing (a timer, every tick) is stopped after
        // three errors, with one notice, instead of filling the
        // notices.
        final id = '${list[0]}';
        owner.scriptErrors[id] = '${list[2]}';
        final n = _errors[id] = (_errors[id] ?? 0) + 1;
        if (n == 1) {
          owner.notice(
            '<canvas_notice from="${_attr(from)}" error="${_attr('${list[2]}')}"/>',
          );
        }
        if (n >= 3) {
          // Not from inside the call into JavaScript.
          scheduleMicrotask(() => stop(id));
          owner.notice(
            '<canvas_notice from="${_attr(from)}" stopped="after 3 errors"/>',
          );
        }
        return true;
      case 'log':
        debugPrint('[$from] ${list[2]}');
        return true;
      case 'element':
        return canvas.elements['${list[2]}']?.toJson();
    }
    return null;
  }

  void dispose() => _js?.dispose();
}

/// The scripts' side: timers, event handlers and the `sg` API.
const _prelude = r'''
(function () {
  // Local times in the host's zone, when the engine gives UTC.
  var off = typeof __SG_TZ_OFFSET_MIN === 'number' ? __SG_TZ_OFFSET_MIN : null;
  if (off === null || new Date().getTimezoneOffset() === -off) return;
  var P = Date.prototype;
  function shifted(d) { return new Date(d.getTime() + off * 60000); }
  ['FullYear', 'Month', 'Date', 'Day', 'Hours', 'Minutes', 'Seconds', 'Milliseconds'].forEach(function (n) {
    var utc = P['getUTC' + n];
    P['get' + n] = function () { return utc.call(shifted(this)); };
  });
  P.getTimezoneOffset = function () { return -off; };
})();
var __sg = (function () {
  var scripts = {};
  var api = {
    width: 1280,
    height: 800,
    state: {},
    dirty: false,
    now: 0,
    load: function (id, factory) {
      var s = { id: id, timers: [], handlers: [], stateHandlers: [], nextTimer: 1 };
      scripts[id] = s;
      var call = function (args) { return sendMessage('sg', JSON.stringify([id].concat(args))); };
      var sg = {
        get width() { return api.width; },
        get height() { return api.height; },
        get state() { return api.state; },
        get: function (k) { return api.state[k]; },
        set: function (k, v) {
          var o = {};
          if (typeof k === 'object') { o = k; } else { o[k] = v; }
          for (var key in o) api.state[key] = o[key];
          // State handlers run after the current handler or timer returns
          // (flush), not inside it.
          api.dirty = true;
          call(['set', o]);
        },
        update: function (elementId, props, transitionMs) {
          return call(['action', { do: 'update', id: elementId, props: props, transition_ms: transitionMs }]);
        },
        put: function (elements) { return call(['action', { do: 'put', elements: [].concat(elements) }]); },
        remove: function (ids) { return call(['action', { do: 'remove', ids: [].concat(ids) }]); },
        animate: function (elementId, opts) {
          var a = { do: 'animate', id: elementId };
          for (var k in opts) a[k] = opts[k];
          return call(['action', a]);
        },
        action: function (a) { return call(['action', a]); },
        sound: function (src, volume) { return call(['action', { do: 'sound', src: src, volume: volume }]); },
        speak: function (text, opts) {
          var a = { do: 'speak', text: String(text) };
          for (var k in (opts || {})) a[k] = opts[k];
          return call(['action', a]);
        },
        stopSpeaking: function () { return call(['action', { do: 'stop_speaking' }]); },
        web: function (elementId, js) { return call(['action', { do: 'web', id: elementId, js: String(js) }]); },
        bgm: function (src, opts) {
          var a = { do: 'bgm', src: src };
          for (var k in (opts || {})) a[k] = opts[k];
          return call(['action', a]);
        },
        element: function (elementId) { return call(['element', elementId]); },
        notify: function (text, opts) { return call(['notify', String(text), opts || {}]); },
        log: function () { call(['log', Array.prototype.join.call(arguments, ' ')]); },
        now: function () { return api.now; },
        every: function (ms, fn) { return addTimer(s, ms, fn, true); },
        after: function (ms, fn) { return addTimer(s, ms, fn, false); },
        cancel: function (handle) { s.timers = s.timers.filter(function (t) { return t.id !== handle; }); },
        on: function (kind, elementId, fn) {
          if (kind === 'state') { s.stateHandlers.push(elementId); return; }
          s.handlers.push({ kind: kind, id: elementId, fn: fn });
        },
      };
      try {
        factory(sg);
        flush();
        return 'ok';
      } catch (e) {
        delete scripts[id];
        return 'error: ' + (e && e.message ? e.message : String(e));
      }
    },
    stop: function (id) { delete scripts[id]; },
    tick: function (now) {
      api.now = now;
      for (var id in scripts) {
        var s = scripts[id];
        var due = s.timers.filter(function (t) { return t.at <= now; });
        for (var i = 0; i < due.length; i++) {
          var t = due[i];
          if (t.repeat) { t.at = now + t.ms; } else { s.timers = s.timers.filter(function (x) { return x !== t; }); }
          run(s, t.fn, []);
          if (!scripts[id]) break;
        }
      }
      flush();
    },
    event: function (e) {
      var handled = false;
      for (var id in scripts) {
        var s = scripts[id];
        for (var i = 0; i < s.handlers.length; i++) {
          var h = s.handlers[i];
          if ((h.kind === e.event || h.kind === '*') && (h.id === e.id || h.id === '*')) {
            handled = true;
            run(s, h.fn, [e]);
          }
        }
      }
      flush();
      return handled;
    },
    onState: function () {
      for (var id in scripts) {
        var s = scripts[id];
        for (var i = 0; i < s.stateHandlers.length; i++) run(s, s.stateHandlers[i], [api.state]);
      }
    },
  };
  // State changed by a script's sg.set: tell the state handlers, a few
  // rounds at most (a handler that sets state again is told on the next
  // tick instead of looping here).
  function flush() {
    for (var round = 0; round < 3 && api.dirty; round++) {
      api.dirty = false;
      api.onState();
    }
  }
  function addTimer(s, ms, fn, repeat) {
    ms = Math.max(50, Number(ms) || 0);
    var t = { id: s.nextTimer++, ms: ms, at: api.now + ms, fn: fn, repeat: repeat };
    s.timers.push(t);
    return t.id;
  }
  function run(s, fn, args) {
    try { fn.apply(null, args); }
    catch (e) {
      sendMessage('sg', JSON.stringify([s.id, 'error', (e && e.message) ? e.message : String(e)]));
    }
  }
  return api;
})();
1;
''';
