// Minimal WebSocket signaling relay for the two-device WebRTC mode.
//
//   dart run bin/signaling_server.dart [--port 8787]
//
// Clients connect to ws://<host>:<port>/?room=<name>. Every text message is
// forwarded unchanged to the other clients in the same room. The server does
// not parse SDP; it only relays, so it can live outside the Pure Dart core.
import 'dart:io';

Future<void> main(List<String> args) async {
  final portIndex = args.indexOf('--port');
  final port = portIndex >= 0 ? int.parse(args[portIndex + 1]) : 8787;
  final rooms = <String, Set<WebSocket>>{};

  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  stdout.writeln('signaling relay on ws://0.0.0.0:$port/?room=<name>');

  await for (final request in server) {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response
        ..statusCode = HttpStatus.ok
        ..write('signaling relay\n');
      await request.response.close();
      continue;
    }
    final room = request.uri.queryParameters['room'] ?? 'default';
    final socket = await WebSocketTransformer.upgrade(request);
    final peers = rooms.putIfAbsent(room, () => {});
    peers.add(socket);
    stdout.writeln('[$room] join (${peers.length} peers)');
    socket.listen(
      (data) {
        for (final other in peers) {
          if (!identical(other, socket)) other.add(data);
        }
      },
      onDone: () {
        peers.remove(socket);
        stdout.writeln('[$room] leave (${peers.length} peers)');
        for (final other in peers) {
          other.add('{"type":"bye"}');
        }
      },
      cancelOnError: true,
    );
  }
}
