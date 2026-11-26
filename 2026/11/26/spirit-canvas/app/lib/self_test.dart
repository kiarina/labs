import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'canvas/canvas_model.dart';
import 'canvas/web_host.dart';
import 'demo_scene.dart';
import 'main.dart';
import 'media.dart';

/// The model-free checks of `check_device.py`, run by the app itself
/// (SELF_TEST=1): for a device the Mac cannot reach on a port (an iPad on
/// Wi-Fi). Writes `results.json` and the pictures into LOG_DIR, then
/// `done.txt`.
Future<void> runSelfTest(HomePageState app) async {
  final dir = env('LOG_DIR', '${Directory.systemTemp.path}/spirit-canvas-logs');
  await Directory(dir).create(recursive: true);
  final results = <String, Object?>{};

  Future<String> tool(String name, Map<String, dynamic> args) async =>
      (await app.runTool(name, args)).text;
  Future<String> web(String id, String js) => WebHost.instance.eval(id, js);
  Future<Map<String, dynamic>> view() async =>
      jsonDecode(await tool('canvas_view', {'image': false}))
          as Map<String, dynamic>;
  Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

  Future<void> step(String label, Future<Object?> Function() body) async {
    final watch = Stopwatch()..start();
    try {
      results[label] = {'ok': true, 'result': await body()};
    } on Object catch (e) {
      results[label] = {'ok': false, 'error': '$e'};
    }
    (results[label] as Map)['seconds'] = watch.elapsedMilliseconds / 1000;
  }

  await wait(3000);
  await step('demo', () async {
    for (final call in kDemoScene) {
      await app.runTool(call.$1, call.$2);
    }
    await wait(4000);
    final v = await view();
    return {
      'canvas': v['canvas'],
      'elements': (v['elements'] as List).length,
      'picture': await app.saveSnapshot('1-demo'),
    };
  });
  await step('layout', () async {
    await tool('canvas_clear', {'background': '#1B2233'});
    await tool('canvas_put', {
      'elements': [
        {
          'id': 'title',
          'type': 'text',
          'anchor': 'top',
          'x': 0,
          'y': 24,
          'w': '90%',
          'h': 60,
          'text': '大きさに合わせる',
          'size': 28,
          'align': 'center',
          'weight': 'bold',
        },
        {
          'id': 'card',
          'type': 'shape',
          'anchor': 'center',
          'x': 0,
          'y': 0,
          'w': '80%',
          'h': '40%',
          'fill': '#2E3A5C',
          'radius': 24,
        },
        {
          'id': 'ok',
          'type': 'button',
          'anchor': 'bottom-right',
          'x': -16,
          'y': -16,
          'w': 140,
          'h': 52,
          'label': 'OK',
        },
      ],
    });
    await wait(1000);
    final v = await view();
    return {
      'canvas': v['canvas'],
      'at': {for (final e in v['elements'] as List) e['id']: e['at']},
      'picture': await app.saveSnapshot('2-layout'),
    };
  });
  await step('behaviors', () async {
    await tool('canvas_clear', {'background': '#20283A'});
    await tool('canvas_put', {
      'elements': [
        {
          'id': 'clock',
          'type': 'text',
          'x': 24,
          'y': 40,
          'w': '90%',
          'h': 60,
          'text': '{{time}}',
          'size': 40,
        },
        {
          'id': 'count',
          'type': 'text',
          'x': 24,
          'y': 110,
          'w': '90%',
          'h': 40,
          'text': '押した回数 {{n}}',
          'size': 24,
        },
        {
          'id': 'btn',
          'type': 'button',
          'x': 24,
          'y': 170,
          'w': 160,
          'h': 52,
          'label': '押す',
          'on': {
            'press': [
              {'do': 'add', 'key': 'n'},
              {'do': 'sound', 'src': 'sounds/sfx/correct.wav'},
            ],
          },
        },
        {
          'id': 'slide',
          'type': 'text',
          'x': 24,
          'y': 250,
          'w': '90%',
          'h': 40,
          'text': '',
          'size': 24,
        },
      ],
    });
    final script = await tool('canvas_script', {
      'id': 'clock',
      'code':
          "function p(n){return (n<10?'0':'')+n}"
          "function s(){var d=new Date();sg.set('time',p(d.getHours())+':'+p(d.getMinutes())+':'+p(d.getSeconds()))}"
          's();sg.every(1000,s);',
    });
    await tool('canvas_timeline', {
      'id': 't',
      'repeat': -1,
      'cycle_ms': 900,
      'steps': [
        {
          'at_ms': 0,
          'actions': [
            {
              'do': 'update',
              'id': 'slide',
              'props': {'text': '1枚目'},
            },
          ],
        },
        {
          'at_ms': 450,
          'actions': [
            {
              'do': 'update',
              'id': 'slide',
              'props': {'text': '2枚目'},
            },
          ],
        },
      ],
    });
    await tool('canvas_audio', {
      'bgm': {'src': 'sounds/bgm/calm.wav', 'volume': 0.3, 'fade_ms': 500},
    });
    for (var i = 0; i < 3; i++) {
      app.canvas.emit(CanvasEvent('press', 'btn'));
    }
    await wait(2200);
    final now = DateTime.now();
    final pic = await app.saveSnapshot('3-behaviors');
    await tool('canvas_audio', {
      'bgm': {'stop': true, 'fade_ms': 300},
    });
    return {
      'script': script,
      'state': {...app.canvas.state},
      'device_time': '${now.hour}:${now.minute}:${now.second}',
      'picture': pic,
    };
  });
  await step('web', () async {
    final page = jsonDecode(_testPage) as Map<String, dynamic>;
    (page['elements'] as List).first.addAll({
      'x': 0,
      'y': 0,
      'w': '100%',
      'h': '100%',
    });
    await tool('canvas_clear', {'background': '#111111'});
    await tool('canvas_put', page);
    final watch = Stopwatch()..start();
    while (watch.elapsedMilliseconds < 15000) {
      if (await web(
            'page',
            "document.readyState === 'complete' && document.images.length > 0",
          ) ==
          'true') {
        break;
      }
      await wait(500);
    }
    final loadS = watch.elapsedMilliseconds / 1000;
    await wait(1000);
    final imgs = await web(
      'page',
      "Array.from(document.images).map(function(i){return [i.src.split('/').pop(), i.naturalWidth]})",
    );
    final bg = await web(
      'page',
      "getComputedStyle(document.querySelector('.bg')).backgroundImage.slice(0,60)",
    );
    await web(
      'page',
      "document.getElementById('b').click(); document.getElementById('b').click(); 'ok'",
    );
    await wait(1500);
    final imgs2 = await web(
      'page',
      "Array.from(document.images).map(function(i){return [i.src.split('/').pop(), i.naturalWidth]})",
    );
    await web(
      'page',
      "window.aud='pending'; new Audio('asset://sounds/sfx/chime.wav').play().then(function(){window.aud='played ok'}).catch(function(e){window.aud='fail '+e}); 1",
    );
    await wait(1500);
    final audio = await web('page', 'window.aud');
    final v = await view();
    return {
      'first_load_s': loadS,
      'images': imgs,
      'css_bg': bg,
      'images_after_clicks': imgs2,
      'audio': audio,
      'state_seen': v['web'],
      'notices': app.behaviors.notices.map((n) => n.line).toList(),
      'picture': await app.saveSnapshot('4-web'),
    };
  });
  await step('scenes', () async {
    final out = <String, Object?>{};
    for (final n in ['space-station-escape', 'mole-garden', 'today-planner']) {
      final r = await tool('canvas_load', {'name': n});
      await wait(2500);
      out[n] = {
        'load': r,
        'canvas': (await view())['canvas'],
        'picture': await app.saveSnapshot('5-$n'),
      };
    }
    final tick = await web(
      'today-planner',
      "document.querySelector('label.task input').click(); JSON.stringify(sg.state)",
    );
    await wait(800);
    out['tick'] = tick;
    out['picture_after_tick'] = await app.saveSnapshot(
      '5-today-planner-ticked',
    );
    return out;
  });
  await File('$dir/results.json')
      .writeAsString(const JsonEncoder.withIndent(' ').convert(results));
  await File('$dir/done.txt').writeAsString(DateTime.now().toIso8601String());
  debugPrint('[self-test] done: $dir');
}

/// The web element of `results/web-test-page.json` (images and a sound by
/// asset://, a button that adds an image and posts an event).
const _testPage = r'''
{"elements":[{"id":"page","type":"web","x":40,"y":40,"w":1200,"h":720,"html":"<!doctype html><html><head><meta charset='utf-8'><style>body{margin:0;font-family:-apple-system;color:#fff;background:#223} .bg{background:url(asset://jpg/street_scene_1774x887_287kb.jpg) center/cover;height:200px} button{font-size:24px;margin:12px}</style></head><body><div class='bg'></div><h1>Web ブロックの試験</h1><img id='a' src='asset://jpg/miineko1_1254x1254_159kb.jpg' width='160'><div id='more'></div><p>押した回数: <span id='n'>0</span></p><button id='b' onclick='press()'>押す</button><script>var n=0;function press(){n++;document.getElementById('n').textContent=n;var i=document.createElement('img');i.width=120;i.src='asset://jpg/objects_1536x1024_358kb.jpg';document.getElementById('more').appendChild(i);sg.setState({count:n});sg.emit('pressed',{count:n},{wake:false});} sg.setState({count:0});</script></body></html>"}]}
''';
