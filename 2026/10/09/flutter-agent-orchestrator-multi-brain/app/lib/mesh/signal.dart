import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../state/thread_view.dart' show Json;

/// One app in the roster.
class SignalNode {
  SignalNode(Json j)
    : name = j['name'] as String,
      brain = j['brain'] == true,
      body = j['body'] as bool? ?? true,
      online = j['online'] == true,
      host = j['host'] as String? ?? '';

  final String name;
  final bool brain;
  final bool body;
  final bool online;
  final String host;
}

/// This app's link to the signaling server (`signal/bin/signal.dart`): the
/// roster, who owns which body, relayed WebRTC signals, and moving bodies
/// between brains. Reconnects on its own.
class SignalClient extends ChangeNotifier {
  SignalClient({
    required this.url,
    required this.name,
    required this.isBrain,
    required this.isBody,
  });

  final String url;

  /// This app's name; the server may change it to keep names unique.
  String name;
  final bool isBrain;
  final bool isBody;

  bool connected = false;
  String link = 'starting';
  List<SignalNode> nodes = const [];
  Map<String, String?> owners = const {};

  // Single-subscription: it holds signals until the peer manager listens.
  // A broadcast stream dropped the brains' offers that arrived between
  // joining and the peer manager starting, and a new app waited 20 s for
  // the retry.
  final _signals = StreamController<(String, Json)>();
  final _assigns = <String, Completer<(bool, String?)>>{};
  int _seq = 0;
  WebSocket? _ws;

  /// A brain's answer to "may this body go to another brain?" (null reason:
  /// yes). Only brains get asked.
  Future<String?> Function(String body)? onReleaseRequest;

  /// WebRTC signals from other apps: (from, data). One listener (the peer
  /// manager).
  Stream<(String, Json)> get signals => _signals.stream;

  /// Link changes and steps, with the time since start.
  final linkLog = <String>[];
  final _clock = Stopwatch()..start();

  void _log(String s) {
    linkLog.add('${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s $s');
    if (linkLog.length > 80) linkLog.removeAt(0);
  }

  void logStep(String s) => _log('  $s');

  String? ownerOf(String body) => owners[body];

  List<String> get brains => [
    for (final n in nodes)
      if (n.brain && n.online) n.name,
  ];

  SignalNode? node(String name) =>
      nodes.where((n) => n.name == name).firstOrNull;

  Future<void> run() async {
    while (true) {
      link = 'connecting to $url';
      _log(link);
      notifyListeners();
      try {
        final ws = await WebSocket.connect(url).timeout(const Duration(seconds: 5));
        _ws = ws;
        ws.add(jsonEncode({
          't': 'hello',
          'name': name,
          'brain': isBrain,
          'body': isBody,
          'host': Platform.localHostname.split('.').first,
        }));
        // One iterator, first message to last (a broadcast stream would
        // drop what arrives while no one listens).
        final it = StreamIterator(ws);
        while (await it.moveNext()) {
          _onMessage((jsonDecode(it.current as String) as Map).cast<String, dynamic>());
        }
        link = 'lost the signaling server';
      } catch (e) {
        link = '$e';
      }
      _ws = null;
      connected = false;
      _log(link);
      notifyListeners();
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  void _onMessage(Json m) {
    switch (m['t']) {
      case 'welcome':
        name = m['name'] as String;
        connected = true;
        link = 'signaling as $name';
        _log(link);
      case 'roster':
        nodes = [
          for (final n in (m['nodes'] as List).cast<Map>())
            SignalNode(n.cast<String, dynamic>()),
        ];
        owners = (m['owners'] as Map).cast<String, String?>();
      case 'signal':
        _signals.add((m['from'] as String, (m['data'] as Map).cast<String, dynamic>()));
        return;
      case 'assignResult':
        _assigns.remove(m['id'])?.complete((m['ok'] == true, m['reason'] as String?));
        return;
      case 'releaseRequest':
        unawaited(() async {
          final reason = await onReleaseRequest?.call(m['body'] as String);
          _send({'t': 'releaseReply', 'id': m['id'], 'ok': reason == null, 'reason': reason});
        }());
        return;
    }
    notifyListeners();
  }

  void _send(Json m) => _ws?.add(jsonEncode(m));

  void sendSignal(String to, Json data) =>
      _send({'t': 'signal', 'to': to, 'data': data});

  /// Moves [body] to [brain] (null: no owner). Fails while the current owner
  /// has workers running or queued there.
  Future<(bool, String?)> assign(String body, String? brain) {
    final id = 'a${++_seq}';
    final c = Completer<(bool, String?)>();
    _assigns[id] = c;
    _send({'t': 'assign', 'id': id, 'body': body, 'brain': brain});
    return c.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => (false, 'no answer from the signaling server'),
    );
  }
}
