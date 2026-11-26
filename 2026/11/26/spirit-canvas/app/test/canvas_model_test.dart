import 'package:flutter_test/flutter_test.dart';

import 'dart:ui';

import 'package:spirit_canvas/canvas/canvas_model.dart';

void main() {
  CanvasAnimation anim(
    List<Map<String, dynamic>> k, {
    int repeat = 1,
    bool alternate = false,
  }) => CanvasAnimation(
    keyframes: k,
    durationMs: 1000,
    repeat: repeat,
    alternate: alternate,
    easing: 'linear',
    startedAt: Duration.zero,
  );

  const base = {'x': 0.0, 'y': 100.0, 'opacity': 1.0};

  test('keyframes spread evenly and interpolate linearly', () {
    final a = anim([
      {'x': 0},
      {'x': 100},
      {'x': 0},
    ]);
    expect(
      a.valuesAt(const Duration(milliseconds: 250), base)['x'],
      closeTo(50, 1e-9),
    );
    expect(
      a.valuesAt(const Duration(milliseconds: 500), base)['x'],
      closeTo(100, 1e-9),
    );
    // Untouched properties are left out (the element keeps its own).
    expect(
      a.valuesAt(const Duration(milliseconds: 500), base).containsKey('y'),
      isFalse,
    );
  });

  test('a property first set later starts from the element value', () {
    final a = anim([
      {'at': 0.5, 'y': 200},
    ]);
    expect(
      a.valuesAt(const Duration(milliseconds: 250), base)['y'],
      closeTo(150, 1e-9),
    );
  });

  test('alternate plays every other cycle backwards; finite repeats stop', () {
    final a = anim(
      [
        {'x': 0},
        {'x': 100},
      ],
      repeat: 2,
      alternate: true,
    );
    expect(
      a.valuesAt(const Duration(milliseconds: 1250), base)['x'],
      closeTo(75, 1e-9),
    );
    expect(a.finishedAt(const Duration(milliseconds: 2000)), isTrue);
    expect(
      a.valuesAt(const Duration(milliseconds: 5000), base)['x'],
      closeTo(0, 1e-9),
    );
  });

  test('a finished move stays where it ended', () {
    final c = CanvasController();
    c.put([
      {'id': 'a', 'type': 'shape', 'x': 0, 'y': 0, 'w': 10, 'h': 10},
    ]);
    c.update('a', {'x': 300}, transitionMs: 1);
    expect(c.animating, isTrue);
    // The controller's clock runs on wall time.
    final until = DateTime.now().add(const Duration(milliseconds: 20));
    while (DateTime.now().isBefore(until)) {}
    expect(c.settle(), isTrue);
    expect(c.elements['a']!.props['x'], 300);
    expect(c.baseValues(c.elements['a']!)['x'], 300);
  });

  test('unknown types and missing ids are reported, not put', () {
    final c = CanvasController();
    final problems = c.put([
      {'id': 'a', 'type': 'sparkles', 'x': 0, 'y': 0, 'w': 1, 'h': 1},
      {'type': 'text', 'x': 0, 'y': 0, 'w': 1, 'h': 1},
    ]);
    expect(problems, hasLength(2));
    expect(c.elements, isEmpty);
  });

  test('% and anchors place by the canvas size, and follow it', () {
    final c = CanvasController()..layout(const Size(400, 800));
    c.put([
      {
        'id': 'center',
        'type': 'shape',
        'anchor': 'center',
        'x': 0,
        'y': 0,
        'w': '50%',
        'h': 100,
      },
      {
        'id': 'corner',
        'type': 'shape',
        'anchor': 'bottom-right',
        'x': -16,
        'y': -16,
        'w': 40,
        'h': 40,
      },
    ]);
    expect(
      c.resolve(c.elements['center']!.props),
      const Rect.fromLTWH(100, 350, 200, 100),
    );
    expect(
      c.resolve(c.elements['corner']!.props),
      const Rect.fromLTWH(344, 744, 40, 40),
    );
    final sizes = <Size>[];
    c.onResize = (from, to) => sizes.add(to);
    c.layout(const Size(1000, 600));
    expect(sizes, [const Size(1000, 600)]);
    expect(c.orientation, 'landscape');
    expect(
      c.resolve(c.elements['center']!.props),
      const Rect.fromLTWH(250, 250, 500, 100),
    );
  });

  test('a design size keeps the canvas fixed and scales it', () {
    final c = CanvasController()..layout(const Size(390, 700));
    c.setDesign(const Size(1280, 800));
    expect(c.size, const Size(1280, 800));
    expect(c.scale, closeTo(390 / 1280, 1e-9));
    c.layout(const Size(800, 700));
    expect(c.size, const Size(1280, 800));
    c.setDesign(null);
    expect(c.size, const Size(800, 700));
  });

  test('an anchored element returns to its layout after an animation', () {
    final c = CanvasController()..layout(const Size(400, 400));
    c.put([
      {
        'id': 'a',
        'type': 'shape',
        'anchor': 'center',
        'x': 0,
        'y': 0,
        'w': 100,
        'h': 100,
      },
    ]);
    c.animate(
      'a',
      keyframes: [
        {'x': 0},
        {'x': 10},
      ],
      durationMs: 16,
    );
    final until = DateTime.now().add(const Duration(milliseconds: 30));
    while (DateTime.now().isBefore(until)) {}
    c.settle();
    expect(c.elements['a']!.props['x'], 0);
    expect(c.baseValues(c.elements['a']!)['x'], 150);
  });
}
