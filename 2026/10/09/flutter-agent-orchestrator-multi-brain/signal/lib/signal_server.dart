// Signaling server for the orchestrator apps: the roster (which apps are
// online, which of them are brains and bodies), body ownership
// (body -> the brains it belongs to), and relaying WebRTC offers, answers and ICE candidates
// between apps. Runs on its own (`bin/signal.dart`) or inside an app.
//
// Every app keeps one WebSocket here. Messages are JSON:
//
//   app -> server  {t: hello, name, brain, body, host} join (the name may be changed)
//                  {t: signal, to, data}             relay to another app
//                  {t: assign, id, body, brains}     set the brains a body belongs to ([] none)
//                  {t: releaseReply, id, ok, reason} a brain's answer to releaseRequest
//   server -> app  {t: welcome, name}
//                  {t: roster, nodes: [{name, brain, body, online, host}], owners: {body: [brain]}}
//                  {t: signal, from, data}
//                  {t: releaseRequest, id, body}     to an owner being removed: may it go?
//                  {t: assignResult, id, ok, reason}
//
// A plain HTTP GET returns the roster and owners as JSON (an app's start
// screen reads it to list the brains).
//
// A body may belong to several brains (a shared body: one of them uses it at
// a time, which the body itself arbitrates). Adding a brain needs no one's
// consent; removing one needs that brain's (no workers of it running or
// queued there), unless it is offline. A brain that is also a body owns
// itself when it first joins; other bodies start with no owner.
//
// No authentication: run it only on a network you trust.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef Json = Map<String, dynamic>;

class SignalNode {
  SignalNode(this.name, this.brain, this.body, this.host, this.socket);

  final String name;
  final bool brain;
  final bool body;
  final String host;
  WebSocket? socket;

  bool get online => socket != null;

  void send(Json m) => socket?.add(jsonEncode(m));

  Json toJson() => {
    'name': name,
    'brain': brain,
    'body': body,
    'online': online,
    'host': host,
  };
}

class SignalServer {
  SignalServer({this.port = 8765, this.ownersFile, this.log = _print});

  final int port;

  /// Where owners are kept across restarts (null: memory only).
  final File? ownersFile;
  final void Function(String line) log;

  final nodes = <String, SignalNode>{};
  final owners = <String, List<String>>{};
  final _releases = <String, Completer<(bool, String?)>>{};
  int _seq = 0;
  HttpServer? _server;

  static void _print(String s) =>
      stdout.writeln('${DateTime.now().toIso8601String()} $s');

  /// Binds the port; throws (SocketException) when it is in use.
  Future<void> start() async {
    if (ownersFile case final f? when f.existsSync()) {
      try {
        for (final e in (jsonDecode(f.readAsStringSync()) as Map).entries) {
          owners[e.key as String] = brainList(e.value);
        }
      } catch (e) {
        log('ignoring ${f.path}: $e');
      }
    }
    final server = _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    log('signaling on :$port');
    unawaited(_accept(server));
  }

  Future<void> close() async {
    await _server?.close(force: true);
    for (final n in nodes.values) {
      await n.socket?.close();
    }
  }

  Future<void> _accept(HttpServer server) async {
    await for (final req in server) {
      if (!WebSocketTransformer.isUpgradeRequest(req)) {
        req.response
          ..headers.contentType = ContentType.json
          ..write(jsonEncode(_roster()));
        await req.response.close();
        continue;
      }
      final ws = await WebSocketTransformer.upgrade(req);
      unawaited(_serve(ws, req.connectionInfo?.remoteAddress.address ?? ''));
    }
  }

  Json _roster() => {
    'nodes': [for (final n in nodes.values) n.toJson()],
    'owners': owners,
  };

  void _broadcastRoster() {
    final m = {'t': 'roster', ..._roster()};
    for (final n in nodes.values) {
      n.send(m);
    }
  }

  void _saveOwners() {
    final f = ownersFile;
    if (f == null) return;
    try {
      f.parent.createSync(recursive: true);
      f.writeAsStringSync(jsonEncode(owners));
    } catch (e) {
      log('could not save ${f.path}: $e');
    }
  }

  Future<void> _serve(WebSocket ws, String address) async {
    SignalNode? me;
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
        // Apps that predate the body flag are all bodies.
        final body = m['body'] as bool? ?? true;
        me = SignalNode(name, brain, body, m['host'] as String? ?? address, ws);
        nodes[name] = me;
        if (body && !owners.containsKey(name)) {
          owners[name] = [if (brain) name];
          _saveOwners();
        }
        log('join $name${brain ? ' (brain)' : ''}${body ? ' (body)' : ''} from $address');
        me.send({'t': 'welcome', 'name': name});
        _broadcastRoster();
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
      _broadcastRoster();
    }
  }

  Future<void> _assign(SignalNode from, Json m) async {
    final body = m['body'] as String;
    final brains = m.containsKey('brains')
        ? brainList(m['brains'])
        : brainList(m['brain']);
    Future<void> reply(bool ok, [String? reason]) async {
      from.send({'t': 'assignResult', 'id': m['id'], 'ok': ok, 'reason': reason});
      log('assign $body -> [${brains.join(', ')}] by ${from.name}: ${ok ? 'ok' : reason}');
    }

    final node = nodes[body];
    if (node == null) return reply(false, 'no app named $body');
    if (!node.body) return reply(false, '$body is not a body');
    for (final b in brains) {
      if (nodes[b]?.brain != true) return reply(false, '$b is not a brain');
    }
    final current = owners[body] ?? const <String>[];
    // Each brain being removed that is online must agree.
    final removed = [
      for (final b in current)
        if (!brains.contains(b) && nodes[b]?.online == true) b,
    ];
    final answers = await Future.wait([
      for (final b in removed) _askRelease(b, body),
    ]);
    for (final (ok, reason) in answers) {
      if (!ok) return reply(false, reason);
    }
    owners[body] = brains;
    _saveOwners();
    _broadcastRoster();
    return reply(true);
  }

  Future<(bool, String?)> _askRelease(String brain, String body) async {
    final id = 'r${++_seq}';
    final answer = Completer<(bool, String?)>();
    _releases[id] = answer;
    nodes[brain]!.send({'t': 'releaseRequest', 'id': id, 'body': body});
    final (ok, reason) = await answer.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _releases.remove(id);
        return (false, '$brain did not answer');
      },
    );
    return (ok, ok ? null : reason ?? '$brain refused');
  }
}

/// The brains a body belongs to, from a list, or a single name or null
/// (owners files and assign messages from before shared bodies).
List<String> brainList(Object? v) => switch (v) {
  final List l => [for (final b in l) '$b'],
  final String s => [s],
  _ => const [],
};
