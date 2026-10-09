// Signaling server for the orchestrator apps: the roster (which apps are
// online, which of them are brains), body ownership (body -> brain), and
// relaying WebRTC offers, answers and ICE candidates between apps.
//
// Every app keeps one WebSocket here. Messages are JSON:
//
//   app -> server  {t: hello, name, brain}           join (the name may be changed)
//                  {t: signal, to, data}             relay to another app
//                  {t: assign, id, body, brain}      move a body (brain null: no owner)
//                  {t: releaseReply, id, ok, reason} a brain's answer to releaseRequest
//   server -> app  {t: welcome, name}
//                  {t: roster, nodes: [{name, brain, online, host}], owners: {body: brain}}
//                  {t: signal, from, data}
//                  {t: releaseRequest, id, body}     to the current owner: may it go?
//                  {t: assignResult, id, ok, reason}
//
// A body may change owner only when its current owner agrees (no workers
// running or queued there) or is offline. A brain's own body belongs to it
// when it first joins; other bodies start with no owner.
//
// No authentication: run it only on a network you trust.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef Json = Map<String, dynamic>;

class Node {
  Node(this.name, this.brain, this.host, this.socket);

  final String name;
  final bool brain;
  final String host;
  WebSocket? socket;

  bool get online => socket != null;

  void send(Json m) => socket?.add(jsonEncode(m));
}

final nodes = <String, Node>{};
final owners = <String, String?>{};
final _releases = <String, Completer<(bool, String?)>>{};
int _seq = 0;

void log(String s) => stdout.writeln('${DateTime.now().toIso8601String()} $s');

void broadcastRoster() {
  final m = {
    't': 'roster',
    'nodes': [
      for (final n in nodes.values)
        {'name': n.name, 'brain': n.brain, 'online': n.online, 'host': n.host},
    ],
    'owners': owners,
  };
  for (final n in nodes.values) {
    n.send(m);
  }
}

Future<void> main(List<String> args) async {
  final port = int.tryParse(
        args.isNotEmpty ? args.first : Platform.environment['PORT'] ?? '',
      ) ??
      8765;
  final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
  log('signaling on :$port');
  await for (final req in server) {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      req.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode({
          'nodes': [
            for (final n in nodes.values)
              {'name': n.name, 'brain': n.brain, 'online': n.online},
          ],
          'owners': owners,
        }));
      await req.response.close();
      continue;
    }
    final ws = await WebSocketTransformer.upgrade(req);
    unawaited(_serve(ws, req.connectionInfo?.remoteAddress.address ?? ''));
  }
}

Future<void> _serve(WebSocket ws, String address) async {
  Node? me;
  await for (final raw in ws) {
    final Json m;
    try {
      m = (jsonDecode(raw as String) as Map).cast<String, dynamic>();
    } catch (_) {
      continue;
    }
    if (me == null) {
      if (m['t'] != 'hello') continue;
      final requested = m['name'] as String;
      var name = requested;
      for (var i = 2; nodes[name]?.online == true; i++) {
        name = '$requested-$i';
      }
      final brain = m['brain'] == true;
      me = Node(name, brain, m['host'] as String? ?? address, ws);
      nodes[name] = me;
      // A brain owns its own body when it first joins.
      if (!owners.containsKey(name)) owners[name] = brain ? name : null;
      log('join $name${brain ? ' (brain)' : ''} from $address');
      me.send({'t': 'welcome', 'name': name});
      broadcastRoster();
      continue;
    }
    switch (m['t']) {
      case 'signal':
        nodes[m['to']]?.send({'t': 'signal', 'from': me.name, 'data': m['data']});
      case 'assign':
        unawaited(_assign(me, m));
      case 'releaseReply':
        _releases.remove(m['id'])?.complete((m['ok'] == true, m['reason'] as String?));
    }
  }
  if (me != null && nodes[me.name] == me) {
    me.socket = null;
    log('leave ${me.name}');
    broadcastRoster();
  }
}

Future<void> _assign(Node from, Json m) async {
  final body = m['body'] as String;
  final brain = m['brain'] as String?;
  Future<void> reply(bool ok, [String? reason]) async {
    from.send({'t': 'assignResult', 'id': m['id'], 'ok': ok, 'reason': reason});
    log('assign $body -> ${brain ?? '(none)'} by ${from.name}: ${ok ? 'ok' : reason}');
  }

  if (!nodes.containsKey(body)) return reply(false, 'no app named $body');
  if (brain != null && nodes[brain]?.brain != true) {
    return reply(false, '$brain is not a brain');
  }
  final current = owners[body];
  if (current == brain) return reply(true);
  final owner = current == null ? null : nodes[current];
  if (owner != null && owner.online) {
    final id = 'r${++_seq}';
    final answer = Completer<(bool, String?)>();
    _releases[id] = answer;
    owner.send({'t': 'releaseRequest', 'id': id, 'body': body});
    final (ok, reason) = await answer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _releases.remove(id);
        return (false, '$current did not answer');
      },
    );
    if (!ok) return reply(false, reason ?? '$current refused');
  }
  owners[body] = brain;
  broadcastRoster();
  return reply(true);
}
