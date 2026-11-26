import 'package:flutter_test/flutter_test.dart';
import 'package:spirit_canvas/canvas/behaviors.dart';
import 'package:spirit_canvas/canvas/canvas_model.dart';

void main() {
  late CanvasController canvas;
  late CanvasBehaviors b;
  final woken = <List<String>>[];

  setUp(() {
    canvas = CanvasController();
    woken.clear();
    b = CanvasBehaviors(canvas, wake: woken.add);
  });
  tearDown(() => b.dispose());

  test(
    'an element without `on` wakes the spirit; with `on` it is told later',
    () {
      canvas.put([
        {'id': 'plain', 'type': 'button', 'x': 0, 'y': 0, 'w': 1, 'h': 1},
        {
          'id': 'local',
          'type': 'button',
          'x': 0,
          'y': 0,
          'w': 1,
          'h': 1,
          'on': {
            'press': [
              {'do': 'add', 'key': 'count'},
              {
                'do': 'update',
                'id': 'plain',
                'props': {'label': 'pressed'},
              },
            ],
          },
        },
      ]);
      expect(b.handleEvent(CanvasEvent('press', 'plain')), 'now');
      expect(b.handleEvent(CanvasEvent('press', 'local')), 'later');
      expect(b.handleEvent(CanvasEvent('press', 'local')), 'later');
      expect(canvas.state['count'], 2);
      expect(canvas.elements['plain']!.props['label'], 'pressed');
    },
  );

  test('choose maps values to actions, with * as the fallback and \$value', () {
    canvas.put([
      {
        'id': 'q',
        'type': 'choices',
        'x': 0,
        'y': 0,
        'w': 1,
        'h': 1,
        'notify': 'none',
        'on': {
          'choose': {
            'a': [
              {'do': 'set', 'key': 'result', 'value': 'right'},
            ],
            '*': [
              {'do': 'set', 'key': 'result', 'value': r'wrong: $value'},
            ],
          },
        },
      },
    ]);
    expect(b.handleEvent(CanvasEvent('choose', 'q', 'b')), 'none');
    expect(canvas.state['result'], 'wrong: b');
    b.handleEvent(CanvasEvent('choose', 'q', 'a'));
    expect(canvas.state['result'], 'right');
  });

  test('templates show state values', () {
    canvas.setState({'n': 3.0, 'name': 'ミア'});
    expect(canvas.render('{{name}}: {{ n }} / {{missing}}'), 'ミア: 3 / ');
  });

  test('a timeline runs its steps in order and repeats', () async {
    b.defineTimeline(
      't',
      [
        {
          'at_ms': 0,
          'actions': [
            {'do': 'add', 'key': 'ticks'},
          ],
        },
        {
          'at_ms': 60,
          'actions': [
            {'do': 'add', 'key': 'ticks'},
          ],
        },
      ],
      repeat: 2,
      cycleMs: 120,
    );
    await Future<void>.delayed(const Duration(milliseconds: 450));
    expect(canvas.state['ticks'], 4);
    expect(b.timelines['t']!.running, isFalse);
  });

  test(
    'notify actions: later as notices, wake rate limited into one',
    () async {
      b.runActions([
        {'do': 'notify', 'text': 'a'},
        {'do': 'notify', 'text': 'b', 'wake': true},
        {'do': 'notify', 'text': 'c', 'wake': true},
      ], from: 'test');
      expect(b.takeNotices(), hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(woken, hasLength(1));
      expect(woken.single, hasLength(2));
    },
  );
}
