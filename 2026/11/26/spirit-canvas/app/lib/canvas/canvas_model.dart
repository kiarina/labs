import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// The canvas's fixed logical size. The view scales it to fit the window, so
/// the spirit always places things in the same coordinates.
const double kCanvasWidth = 1280;
const double kCanvasHeight = 800;

const kElementTypes = [
  'text',
  'shape',
  'image',
  'svg',
  'video',
  'audio',
  'vrm',
  'button',
  'choices',
  'input',
];

/// The numeric properties an animation or a transition can move.
const kAnimatable = ['x', 'y', 'w', 'h', 'opacity', 'scale', 'rotation'];

/// One thing on the canvas: a type, an id and its properties as the spirit
/// gave them (JSON). Unknown properties are kept and ignored.
class CanvasElement {
  CanvasElement(this.id, this.type, Map<String, dynamic> props)
    : props = {...props};

  final String id;
  final String type;
  final Map<String, dynamic> props;

  /// Bumped on every change, so views can tell an element changed.
  int version = 0;

  double num_(String key, double fallback) =>
      (props[key] as num?)?.toDouble() ?? fallback;
  String? str(String key) => props[key]?.toString();
  bool flag(String key, bool fallback) => props[key] as bool? ?? fallback;

  double get x => num_('x', 0);
  double get y => num_('y', 0);
  double get w => num_('w', 200);
  double get h => num_('h', 80);
  double get z => num_('z', 0);

  Map<String, dynamic> toJson() => {'id': id, 'type': type, ...props};
}

/// A keyframe animation of an element's numeric properties (absolute
/// values; a property a keyframe leaves out keeps the element's own value).
class CanvasAnimation {
  CanvasAnimation({
    required this.keyframes,
    required this.durationMs,
    required this.repeat,
    required this.alternate,
    required this.easing,
    required this.startedAt,
  });

  final List<Map<String, dynamic>> keyframes;
  final double durationMs;

  /// Times to play; -1 forever.
  final int repeat;
  final bool alternate;
  final String easing;
  final Duration startedAt;

  bool finishedAt(Duration now) {
    if (repeat < 0) return false;
    return (now - startedAt).inMicroseconds / 1000 >= durationMs * repeat;
  }

  /// The animated values at [now], over the element's [base] values.
  Map<String, double> valuesAt(Duration now, Map<String, double> base) {
    final elapsed = (now - startedAt).inMicroseconds / 1000;
    var cycle = (elapsed / durationMs).floor();
    var t = (elapsed % durationMs) / durationMs;
    if (repeat >= 0 && cycle >= repeat) {
      cycle = repeat - 1;
      t = 1;
    }
    if (alternate && cycle.isOdd) t = 1 - t;
    t = _ease(easing, t);
    final frames = [
      for (final (i, k) in keyframes.indexed)
        (
          at:
              (k['at'] as num?)?.toDouble() ??
              (keyframes.length == 1 ? 1.0 : i / (keyframes.length - 1)),
          k: k,
        ),
    ]..sort((a, b) => a.at.compareTo(b.at));
    final out = <String, double>{};
    for (final p in kAnimatable) {
      final withP = [
        for (final f in frames)
          if (f.k[p] is num) (at: f.at, v: (f.k[p] as num).toDouble()),
      ];
      if (withP.isEmpty) continue;
      // Before the first keyframe that sets it, the element's own value.
      final points = [
        if (withP.first.at > 0 && base.containsKey(p)) (at: 0.0, v: base[p]!),
        ...withP,
      ];
      if (t <= points.first.at) {
        out[p] = points.first.v;
      } else if (t >= points.last.at) {
        out[p] = points.last.v;
      } else {
        for (var i = 0; i < points.length - 1; i++) {
          final a = points[i], b = points[i + 1];
          if (t >= a.at && t <= b.at) {
            final u = b.at == a.at ? 1.0 : (t - a.at) / (b.at - a.at);
            out[p] = a.v + (b.v - a.v) * u;
            break;
          }
        }
      }
    }
    return out;
  }
}

double _ease(String easing, double t) => switch (easing) {
  'linear' => t,
  'ease_in' => t * t,
  'ease_out' => 1 - (1 - t) * (1 - t),
  'bounce' => _bounce(t),
  'elastic' =>
    t == 0 || t == 1
        ? t
        : math.pow(2, -10 * t) * math.sin((t * 10 - 0.75) * (2 * math.pi / 3)) +
              1,
  _ => t < 0.5 ? 2 * t * t : 1 - math.pow(-2 * t + 2, 2) / 2,
}.toDouble();

double _bounce(double t) {
  const n = 7.5625, d = 2.75;
  if (t < 1 / d) return n * t * t;
  if (t < 2 / d) return n * (t -= 1.5 / d) * t + 0.75;
  if (t < 2.5 / d) return n * (t -= 2.25 / d) * t + 0.9375;
  return n * (t -= 2.625 / d) * t + 0.984375;
}

/// Long SVG markup and frames, shortened for the spirit's `canvas_view`
/// (it wrote them itself; sending them back every look fills its context).
Map<String, dynamic> _abbreviated(CanvasElement e) => {
  if (e.props['markup'] case final String m when m.length > 300)
    'markup': '(svg, ${m.length} chars, omitted)',
  if (e.props['frames'] case final List f)
    'frames': '(${f.length} svg frames, omitted)',
};

/// Something the user did on the canvas, for the spirit.
class CanvasEvent {
  CanvasEvent(this.kind, this.id, [this.value]);

  /// `press` (button), `choose` (choices), `submit` (input), `tap` (any
  /// element with `tappable`), `ended` (video or audio that finished).
  final String kind;
  final String id;
  final Object? value;
  final at = DateTime.now();

  Map<String, dynamic> toJson() => {
    'event': kind,
    'id': id,
    'value': ?value,
    'at': at.toIso8601String(),
  };
}

/// The canvas: its elements and running animations, changed by the spirit's
/// tools and watched by the view.
class CanvasController extends ChangeNotifier {
  final elements = <String, CanvasElement>{};
  final animations = <String, CanvasAnimation>{};

  /// The stage's color (`#RRGGBB`); null for the default dark one.
  String? background;

  /// Shared values that texts show (`{{name}}`), set by the spirit
  /// (`canvas_state`), actions (`set`, `add`) and scripts (`sg.set`).
  final state = <String, dynamic>{};

  void setState(Map<String, dynamic> values) {
    state.addAll(values);
    notifyListeners();
  }

  static final _template = RegExp(r'\{\{\s*([\w.]+)\s*\}\}');

  /// [text] with `{{name}}` replaced by the state's values.
  String render(String text) => text.replaceAllMapped(_template, (m) {
    final v = state[m[1]];
    if (v == null) return '';
    if (v is double && v == v.roundToDouble()) return v.toInt().toString();
    return '$v';
  });

  /// The clock animations run on (the view's ticker).
  final _clock = Stopwatch()..start();
  Duration get now => _clock.elapsed;

  /// Events from the user, for the spirit.
  void Function(CanvasEvent event)? onEvent;

  /// The latest event of each input, so the spirit can read values the
  /// user typed without submitting.
  final inputValues = <String, String>{};

  void emit(CanvasEvent e) => onEvent?.call(e);

  List<CanvasElement> get ordered =>
      elements.values.toList()..sort((a, b) => a.z.compareTo(b.z));

  /// Puts elements, replacing any with the same id. Returns problems.
  List<String> put(List<Map<String, dynamic>> items) {
    final problems = <String>[];
    for (final item in items) {
      final id = item['id']?.toString();
      final type = item['type']?.toString();
      if (id == null || id.isEmpty) {
        problems.add('an element without id was skipped');
        continue;
      }
      if (!kElementTypes.contains(type)) {
        problems.add('$id: unknown type "$type" (use one of $kElementTypes)');
        continue;
      }
      final props = {...item}
        ..remove('id')
        ..remove('type');
      animations.remove(id);
      elements[id] = CanvasElement(id, type!, props);
    }
    notifyListeners();
    return problems;
  }

  /// Merges [props] into the element. With [transitionMs], numeric
  /// properties move there smoothly instead of jumping.
  String? update(
    String id,
    Map<String, dynamic> props, {
    double? transitionMs,
    String easing = 'ease_in_out',
  }) {
    final e = elements[id];
    if (e == null) return 'no element "$id"';
    final moving = {
      for (final p in kAnimatable)
        if (props[p] is num) p: (props[p] as num).toDouble(),
    };
    if (transitionMs != null && transitionMs > 0 && moving.isNotEmpty) {
      final from = currentValues(e);
      animations[id] = CanvasAnimation(
        keyframes: [
          {'at': 0, for (final p in moving.keys) p: from[p]},
          {'at': 1, ...moving},
        ],
        durationMs: transitionMs,
        repeat: 1,
        alternate: false,
        easing: easing,
        startedAt: now,
      );
    } else {
      animations.remove(id);
    }
    e.props.addAll(props);
    e.version++;
    notifyListeners();
    return null;
  }

  List<String> remove(List<String> ids) {
    final missing = <String>[];
    for (final id in ids) {
      if (elements.remove(id) == null) missing.add(id);
      animations.remove(id);
    }
    notifyListeners();
    return missing;
  }

  void clear({String? background}) {
    this.background = background;
    elements.clear();
    animations.clear();
    inputValues.clear();
    notifyListeners();
  }

  String? animate(
    String id, {
    required List<Map<String, dynamic>> keyframes,
    required double durationMs,
    int repeat = 1,
    bool alternate = false,
    String easing = 'ease_in_out',
  }) {
    if (!elements.containsKey(id)) return 'no element "$id"';
    if (keyframes.isEmpty) return 'no keyframes';
    animations[id] = CanvasAnimation(
      keyframes: keyframes,
      durationMs: math.max(16, durationMs),
      repeat: repeat == 0 ? 1 : repeat,
      alternate: alternate,
      easing: easing,
      startedAt: now,
    );
    notifyListeners();
    return null;
  }

  Map<String, double> baseValues(CanvasElement e) => {
    'x': e.x,
    'y': e.y,
    'w': e.w,
    'h': e.h,
    'opacity': e.num_('opacity', 1),
    'scale': e.num_('scale', 1),
    'rotation': e.num_('rotation', 0),
  };

  /// The element's values now, with its animation applied.
  Map<String, double> currentValues(CanvasElement e) {
    final base = baseValues(e);
    final a = animations[e.id];
    if (a == null) return base;
    return {...base, ...a.valuesAt(now, base)};
  }

  /// Drops finished animations, keeping their last values on the element
  /// (so a finished move stays where it ended). True if any finished.
  bool settle() {
    final done = [
      for (final MapEntry(:key, :value) in animations.entries)
        if (value.finishedAt(now)) key,
    ];
    for (final id in done) {
      final e = elements[id];
      final a = animations.remove(id)!;
      if (e != null) e.props.addAll(a.valuesAt(now, baseValues(e)));
    }
    return done.isNotEmpty;
  }

  bool get animating => animations.isNotEmpty;

  /// A text description of the canvas for the spirit.
  List<Map<String, dynamic>> describe({bool abbreviate = false}) => [
    for (final e in ordered)
      {
        ...e.toJson(),
        if (abbreviate) ..._abbreviated(e),
        if (animations[e.id] case final a?)
          'animating': {
            'duration_ms': a.durationMs,
            'repeat': a.repeat,
            'now': {
              for (final MapEntry(:key, :value) in currentValues(e).entries)
                key: double.parse(value.toStringAsFixed(1)),
            },
          },
        if (e.type == 'input' && inputValues[e.id] != null)
          'typed': inputValues[e.id],
      },
  ];
}
