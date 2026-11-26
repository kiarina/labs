import 'dart:convert';
import 'dart:io';

import 'canvas/canvas_model.dart';
import 'demo_scene.dart';
import 'main.dart';

/// A loopback-only HTTP port for driving the lab from scripts (CONTROL_PORT):
/// send messages, switch modes, fire canvas events, save snapshots and read
/// the state. Off unless CONTROL_PORT is given.
class ControlServer {
  ControlServer._(this._server);

  final HttpServer _server;

  static Future<ControlServer> start(int port, HomePageState app) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    server.listen((req) async {
      final q = req.uri.queryParameters;
      Object? out;
      try {
        switch (req.uri.path) {
          case '/state':
            out = {
              'mode': app.mode,
              'running': app.spirit.running,
              'model': app.spirit.model,
              'entries': [
                for (final e in app.spirit.entries)
                  {
                    'role': e.role,
                    'tool': ?e.tool,
                    'text': e.text,
                    'at': e.at.toIso8601String(),
                  },
              ],
              'timings': [
                for (final t in app.spirit.timings)
                  {
                    for (final MapEntry(:key, :value) in t.entries)
                      key: value is DateTime ? value.toIso8601String() : value,
                  },
              ],
              'canvas': app.canvas.describe(),
              'behaviors': app.behaviors.describe(),
              'notices': [for (final n in app.behaviors.notices) n.line],
            };
          case '/send':
            final text = await utf8.decodeStream(req);
            await app.sendUser(text);
            out = {'ok': true};
          case '/mode':
            app.setMode(q['m'] ?? 'canvas');
            out = {'ok': true};
          case '/event':
            final raw = q['value'];
            Object? value = raw;
            if (raw != null && raw.startsWith('[')) value = jsonDecode(raw);
            app.canvas.emit(
              CanvasEvent(q['kind'] ?? 'press', q['id'] ?? '', value),
            );
            out = {'ok': true};
          case '/snapshot':
            final path = await app.saveSnapshot(q['name'] ?? 'snapshot');
            out = {
              'path': path,
              // On a phone the file is inside the app; send it back too.
              if (q['inline'] == '1' && path != null)
                'png': base64Encode(await File(path).readAsBytes()),
            };
          case '/demo':
            for (final call in kDemoScene) {
              await app.runTool(call.$1, call.$2);
            }
            out = {'ok': true};
          case '/tool':
            // Runs one canvas tool as the spirit would (no model).
            final args = jsonDecode(await utf8.decodeStream(req));
            final r = await app.runTool(
              q['name'] ?? '',
              (args as Map).cast<String, dynamic>(),
            );
            out = {'ok': r.ok, 'text': r.text, 'images': r.images.length};
          case '/clear':
            app.canvas.clear();
            out = {'ok': true};
          default:
            req.response.statusCode = 404;
            out = {'error': 'unknown path'};
        }
      } catch (e) {
        req.response.statusCode = 500;
        out = {'error': '$e'};
      }
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(out));
      await req.response.close();
    });
    return ControlServer._(server);
  }

  Future<void> close() => _server.close(force: true);
}
