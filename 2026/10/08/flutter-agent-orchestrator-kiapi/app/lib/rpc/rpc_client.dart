import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A notification from a child process (no `id`).
class ServerNotification {
  ServerNotification(this.method, this.params);

  final String method;
  final Map<String, dynamic> params;
}

/// A request from a child process that waits for our answer (approvals,
/// dynamic tool calls, permission prompts).
class ServerRequest {
  ServerRequest(this.id, this.method, this.params);

  final Object id;
  final String method;
  final Map<String, dynamic> params;
}

class RpcError implements Exception {
  RpcError(this.code, this.message, [this.data]);

  final int code;
  final String message;
  final Object? data;

  @override
  String toString() => 'RpcError($code): $message';
}

class ProtocolLogEntry {
  ProtocolLogEntry(this.source, this.outgoing, this.line) : at = DateTime.now();

  /// 'codex' or 'claude'.
  final String source;
  final bool outgoing;
  final String line;
  final DateTime at;
}

/// Newline-delimited JSON-RPC without the `jsonrpc` field, over a child
/// process's stdio. Both `codex app-server` and the Agent SDK bridge
/// (`sidecar/`) speak it.
class RpcClient {
  RpcClient({
    required this.name,
    required this.executable,
    this.arguments = const [],
    this.workingDirectory,
    this.environment,
  });

  final String name;
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;
  final Map<String, String>? environment;

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

  Future<void> start() async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
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
          c.completeError(RpcError(-1, '$name exited ($code)'));
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
    _log.add(ProtocolLogEntry(name, true, line));
    _process?.stdin.writeln(line);
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) return;
    _log.add(ProtocolLogEntry(name, false, line));
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
          RpcError(
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

/// `codex app-server`. GUI apps do not get the shell PATH, so look in the
/// usual install locations; CODEX_BIN overrides.
Future<RpcClient> codexAppServer({
  String name = 'codex',
  List<String> extraArguments = const [],
  Map<String, String>? environment,
}) async {
  final env = Platform.environment;
  final explicit = env['CODEX_BIN'];
  final home = env['HOME'] ?? '';
  final candidates = [
    if (explicit != null && explicit.isNotEmpty) explicit,
    '/opt/homebrew/bin/codex',
    '/usr/local/bin/codex',
    '$home/.local/bin/codex',
  ];
  for (final c in candidates) {
    if (await File(c).exists()) {
      return RpcClient(
        name: name,
        executable: c,
        arguments: ['app-server', ...extraArguments],
        environment: environment,
      );
    }
  }
  return RpcClient(
    name: name,
    executable: '/bin/zsh',
    arguments: [
      '-lc',
      r'exec codex "$@"',
      'codex',
      'app-server',
      ...extraArguments,
    ],
    environment: environment,
  );
}

/// A second `codex app-server` whose model provider is kiapi
/// (KIAPI_BASE_URL, default http://127.0.0.1:8500; KIAPI_MODEL, default
/// qwen3.8-flash-next). It gets a CODEX_HOME of its own (no MCP servers,
/// skills or login from ~/.codex) and a model catalog entry that sends tools
/// as plain functions: the catalog entries of OpenAI's models use code mode
/// and `additional_tools`, which kiapi does not accept. Both settings are
/// read at process start only, hence a process of its own.
Future<RpcClient> kiapiAppServer(String stateDir) async {
  final env = Platform.environment;
  final base = (env['KIAPI_BASE_URL'] ?? 'http://127.0.0.1:8500').replaceAll(
    RegExp(r'/+$'),
    '',
  );
  final model = env['KIAPI_MODEL'] ?? 'qwen3.8-flash-next';
  final home = Directory('$stateDir/kiapi-codex-home');
  await home.create(recursive: true);
  final catalog = File('${home.path}/models.json');
  await catalog.writeAsString(
    jsonEncode({
      'models': [await _kiapiCatalogEntry(model)],
    }),
  );
  const off = [
    'code_mode_host',
    'multi_agent',
    'apps',
    'plugins',
    'image_generation',
    'computer_use',
    'browser_use',
    'browser_use_external',
    'in_app_browser',
    'goals',
    'tool_suggest',
    'skill_search',
    'memories',
  ];
  return codexAppServer(
    name: 'kiapi',
    extraArguments: [
      for (final o in [
        'model_providers.kiapi={name="kiapi", base_url="$base/v1", wire_api="responses"}',
        'model_provider="kiapi"',
        'model="$model"',
        'model_catalog_json="${catalog.path}"',
        'web_search="disabled"',
        'skills.include_instructions=false',
        for (final f in off) 'features.$f=false',
      ]) ...['-c', o],
    ],
    environment: {'CODEX_HOME': home.path},
  );
}

/// The catalog entry of an OpenAI model from ~/.codex/models_cache.json,
/// renamed to the kiapi model and switched to plain function tools. The
/// catalog's types are strict, so only the fields that matter change.
Future<Map<String, dynamic>> _kiapiCatalogEntry(String model) async {
  final home = Platform.environment['HOME'] ?? '';
  final cache =
      jsonDecode(await File('$home/.codex/models_cache.json').readAsString())
          as Map<String, dynamic>;
  final models = (cache['models'] as List).cast<Map<String, dynamic>>();
  final base =
      models.where((m) => m['slug'] == 'gpt-5.6-luna').firstOrNull ??
      models.first;
  return {
    ...base,
    'slug': model,
    'display_name': model,
    'description': 'kiapi local model',
    'priority': 0,
    'tool_mode': null,
    'multi_agent_version': null,
    'apply_patch_tool_type': null,
    'use_responses_lite': false,
    'supports_search_tool': false,
    'experimental_supported_tools': <Object>[],
    'include_skills_usage_instructions': false,
    'include_apps_usage_instructions': false,
    'include_plugin_usage_instructions': false,
    'node_repl_disabled': true,
    'service_tiers': <Object>[],
    'additional_speed_tiers': <Object>[],
    'context_window': 200000,
    'max_context_window': 200000,
  };
}

/// The Agent SDK bridge (`sidecar/src/main.ts`), run by Node.
/// CLAUDE_FLUTTER_SIDECAR points at the sidecar directory; NODE_BIN at node.
RpcClient claudeBridge() {
  final env = Platform.environment;
  final sidecar = env['CLAUDE_FLUTTER_SIDECAR'];
  if (sidecar == null || sidecar.isEmpty) {
    throw StateError('Set CLAUDE_FLUTTER_SIDECAR to the sidecar directory');
  }
  final node = env['NODE_BIN'];
  if (node != null && node.isNotEmpty) {
    return RpcClient(
      name: 'claude',
      executable: node,
      arguments: ['src/main.ts'],
      workingDirectory: sidecar,
    );
  }
  return RpcClient(
    name: 'claude',
    executable: '/bin/zsh',
    arguments: ['-lc', r'exec node "$@"', 'node', 'src/main.ts'],
    workingDirectory: sidecar,
  );
}
