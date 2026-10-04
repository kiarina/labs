import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A notification sent by the bridge (no `id`).
class ServerNotification {
  ServerNotification(this.method, this.params);

  final String method;
  final Map<String, dynamic> params;
}

/// A request sent by the bridge that expects a response from the app
/// (permission prompts).
class ServerRequest {
  ServerRequest(this.id, this.method, this.params);

  final Object id;
  final String method;
  final Map<String, dynamic> params;
}

class BridgeError implements Exception {
  BridgeError(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'BridgeError($code): $message';
}

/// One line of the protocol, kept for the debug panel.
class ProtocolLogEntry {
  ProtocolLogEntry(this.outgoing, this.line) : at = DateTime.now();

  final bool outgoing;
  final String line;
  final DateTime at;
}

/// Talks to the Agent SDK bridge (`sidecar/src/main.ts`) over stdio:
/// newline-delimited JSON-RPC without the `jsonrpc` field.
class BridgeClient {
  BridgeClient({required this.executable, this.arguments = const []});

  final String executable;
  final List<String> arguments;

  Process? _process;
  int _nextId = 0;
  final _pending = <Object, Completer<dynamic>>{};
  final _notifications = StreamController<ServerNotification>.broadcast();
  final _requests = StreamController<ServerRequest>.broadcast();
  final _log = StreamController<ProtocolLogEntry>.broadcast();
  final _exit = Completer<int>();
  final stderrLines = <String>[];

  Stream<ServerNotification> get notifications => _notifications.stream;
  Stream<ServerRequest> get requests => _requests.stream;
  Stream<ProtocolLogEntry> get log => _log.stream;
  Future<int> get exitCode => _exit.future;
  bool get isRunning => _process != null && !_exit.isCompleted;

  Future<void> start({String? workingDirectory}) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    _process = process;
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          stderrLines.add(line);
          if (stderrLines.length > 500) stderrLines.removeAt(0);
        });
    unawaited(
      process.exitCode.then((code) {
        if (!_exit.isCompleted) _exit.complete(code);
        for (final c in _pending.values) {
          c.completeError(BridgeError(-1, 'bridge exited ($code)'));
        }
        _pending.clear();
      }),
    );
  }

  Future<dynamic> request(String method, [Map<String, dynamic>? params]) {
    final id = ++_nextId;
    final completer = Completer<dynamic>();
    _pending[id] = completer;
    _send({'id': id, 'method': method, 'params': ?params});
    return completer.future;
  }

  void notify(String method, [Map<String, dynamic>? params]) {
    _send({'method': method, 'params': ?params});
  }

  void respond(Object id, Object? result) {
    _send({'id': id, 'result': result});
  }

  void respondError(Object id, int code, String message) {
    _send({
      'id': id,
      'error': {'code': code, 'message': message},
    });
  }

  void _send(Map<String, dynamic> message) {
    final line = jsonEncode(message);
    _log.add(ProtocolLogEntry(true, line));
    _process?.stdin.writeln(line);
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    _log.add(ProtocolLogEntry(false, line));
    final Map<String, dynamic> message;
    try {
      message = (jsonDecode(line) as Map).cast<String, dynamic>();
    } on FormatException {
      return;
    }
    final id = message['id'];
    final method = message['method'] as String?;
    final params =
        (message['params'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    if (method != null && id != null) {
      _requests.add(ServerRequest(id as Object, method, params));
    } else if (method != null) {
      _notifications.add(ServerNotification(method, params));
    } else if (id != null) {
      final completer = _pending.remove(id);
      if (completer == null) return;
      final error = message['error'];
      if (error is Map) {
        completer.completeError(
          BridgeError(
            (error['code'] as num?)?.toInt() ?? 0,
            error['message'] as String? ?? 'unknown error',
            error['data'],
          ),
        );
      } else {
        completer.complete(message['result']);
      }
    }
  }

  Future<void> dispose() async {
    _process?.kill();
    await _notifications.close();
    await _requests.close();
    await _log.close();
  }
}

/// The command that runs the bridge. GUI apps on macOS do not inherit the
/// shell PATH, so `node` is started through a login shell unless NODE_BIN is
/// set. CLAUDE_FLUTTER_SIDECAR points at the `sidecar` directory.
(String, List<String>, String) resolveBridgeCommand() {
  final env = Platform.environment;
  final sidecar = env['CLAUDE_FLUTTER_SIDECAR'];
  if (sidecar == null || sidecar.isEmpty) {
    throw StateError('Set CLAUDE_FLUTTER_SIDECAR to the sidecar directory');
  }
  final node = env['NODE_BIN'];
  if (node != null && node.isNotEmpty) {
    return (node, ['src/main.ts'], sidecar);
  }
  // `zsh -lc 'exec node "$@"' node src/main.ts`
  return (
    '/bin/zsh',
    ['-lc', r'exec node "$@"', 'node', 'src/main.ts'],
    sidecar,
  );
}
