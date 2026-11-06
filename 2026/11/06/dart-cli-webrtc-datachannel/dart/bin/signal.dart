/// A two-party WebSocket relay for the lab: every text message from one
/// client goes to the other. When both are present, each gets
/// `{"k":"peer"}`. Listens on 0.0.0.0 so a container can reach it.
///
///   dart run bin/signal.dart [port]
library;

import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? int.parse(args[0]) : 8899;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('signal listening on :$port');
  final clients = <WebSocket>[];
  await for (final req in server) {
    if (req.uri.path == '/stop') {
      req.response.write('bye');
      await req.response.close();
      for (final c in clients) {
        await c.close();
      }
      await server.close(force: true);
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response.statusCode = 404;
      await req.response.close();
      continue;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    if (clients.length >= 2) {
      // A new session: drop the old pair.
      for (final c in clients) {
        await c.close();
      }
      clients.clear();
    }
    clients.add(ws);
    stdout.writeln('client joined (${clients.length})');
    if (clients.length == 2) {
      for (final c in clients) {
        c.add(jsonEncode({'k': 'peer'}));
      }
    }
    ws.listen(
      (data) {
        for (final c in clients) {
          if (!identical(c, ws)) c.add(data);
        }
      },
      onDone: () {
        clients.remove(ws);
        stdout.writeln('client left (${clients.length})');
      },
    );
  }
}
