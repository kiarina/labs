import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'rpc_client.dart';

String env(String name, [String fallback = '']) {
  final v = Platform.environment[name];
  return v == null || v.isEmpty ? fallback : v;
}

/// One entry of the conversation, as the chat history shows it.
class ChatEntry {
  ChatEntry(this.role, this.text, {this.tool, this.mode});

  /// `user`, `spirit`, `tool`, `event` or `error`.
  final String role;
  String text;

  /// For `tool`: the tool's name.
  final String? tool;

  /// The mode the user was in when this was sent.
  final String? mode;
  final at = DateTime.now();
  bool done = false;
}

class ToolOutcome {
  ToolOutcome(this.text, {this.images = const [], this.ok = true});

  final String text;

  /// PNGs, base64.
  final List<String> images;
  final bool ok;
}

typedef ToolHandler = Future<ToolOutcome> Function(
  String name,
  Map<String, dynamic> args,
);

/// Codex features off for the spirit's thread: it has no hands but the
/// canvas tools.
const _featuresOff = {
  'shell_tool': false,
  'unified_exec': false,
  'computer_use': false,
  'browser_use': false,
  'browser_use_external': false,
  'in_app_browser': false,
  'apps': false,
  'plugins': false,
  'goals': false,
  'image_generation': false,
  'multi_agent': false,
  'view_image': false,
};

/// Model catalog fields that turn Codex's code mode off, so the canvas tools
/// reach the model as plain functions and `canvas_view`'s picture stays an
/// image (in code mode a tool's result becomes one string).
const _directToolsFields = <String, dynamic>{
  'tool_mode': null,
  'multi_agent_version': null,
  'apply_patch_tool_type': null,
  'supports_search_tool': false,
  'experimental_supported_tools': <Object>[],
  'include_skills_usage_instructions': false,
  'include_apps_usage_instructions': false,
  'include_plugin_usage_instructions': false,
  'node_repl_disabled': true,
};

/// The agent: one `codex app-server` thread with the canvas tools.
class Agent extends ChangeNotifier {
  Agent({
    required this.instructions,
    required this.tools,
    required this.onTool,
  });

  final String instructions;
  final List<Map<String, dynamic>> tools;
  final ToolHandler onTool;

  RpcClient? _client;
  String? threadId;
  String? model;
  String? activeTurn;
  String status = 'starting';
  final entries = <ChatEntry>[];
  final _byItem = <String, ChatEntry>{};

  /// Called with the spirit's text as it streams in (for the caption).
  void Function(ChatEntry entry)? onSpiritText;

  /// Per turn: when it started, when the first tool call came, when it
  /// ended (for the lab's latency notes).
  final timings = <Map<String, dynamic>>[];
  Map<String, dynamic>? _timing;
  final _log = <String>[];

  /// A JSONL log of every message to and from Codex (LOG_DIR, if set).
  IOSink? _logSink;

  bool get running => activeTurn != null || _starting;
  bool _starting = false;

  Future<void> start({String? model, String? effort}) async {
    final catalog = await _writeCatalog();
    final client = await codexAppServer(
      extra: ['-c', 'model_catalog_json=${jsonEncode(catalog)}'],
    );
    _client = client;
    final logDir = env('LOG_DIR');
    if (logDir.isNotEmpty) {
      await Directory(logDir).create(recursive: true);
      final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      _logSink = File('$logDir/session-$stamp.jsonl').openWrite();
      client.log.listen((l) {
        _logSink?.writeln(
          jsonEncode({
            'at': l.at.toIso8601String(),
            'out': l.outgoing,
            'line': l.line,
          }),
        );
      });
    }
    await client.start();
    client.notifications.listen(_onNotification);
    client.requests.listen(_onRequest);
    await client.request('initialize', {
      'clientInfo': {
        'name': 'ardy_vrm_agent',
        'title': 'ARDY VRM agent lab',
        'version': '0.1.0',
      },
      'capabilities': {'experimentalApi': true, 'requestAttestation': false},
    });
    client.notify('initialized');
    final cwd = await Directory.systemTemp.createTemp('ardy-vrm-agent-');
    final r = await client.request('thread/start', {
      'cwd': cwd.path,
      'model': ?model,
      'approvalPolicy': 'never',
      'sandbox': 'read-only',
      'config': {
        'features': _featuresOff,
        'include_permissions_instructions': false,
        'include_environment_context': false,
        'web_search': 'disabled',
      },
      'dynamicTools': [
        for (final t in tools) {'type': 'function', ...t},
      ],
      'developerInstructions': instructions,
    }) as Map;
    threadId = (r['thread'] as Map)['id'] as String;
    this.model = r['model'] as String?;
    _effort = effort;
    status = 'ready';
    notifyListeners();
  }

  String? _effort;

  /// ~/.codex/models_cache.json with code mode off for every model.
  Future<String> _writeCatalog() async {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final cache = File('$home/.codex/models_cache.json');
    if (!await cache.exists()) {
      throw StateError('Codex has no model list yet: run `codex` once');
    }
    final models =
        ((jsonDecode(await cache.readAsString()) as Map)['models'] as List)
            .cast<Map<String, dynamic>>();
    final out = File('${Directory.systemTemp.path}/ardy-vrm-agent-models.json');
    await out.writeAsString(
      jsonEncode({
        'models': [
          for (final m in models) {...m, ..._directToolsFields},
        ],
      }),
    );
    return out.path;
  }

  /// Sends the user's text (or canvas events): a new turn, or steered into
  /// the running one.
  Future<void> send(String text, {required String role, String? mode}) async {
    final client = _client;
    final thread = threadId;
    if (client == null || thread == null) return;
    entries.add(ChatEntry(role, text, mode: mode)..done = true);
    notifyListeners();
    final input = [
      {'type': 'text', 'text': text, 'text_elements': <Object>[]},
    ];
    try {
      if (activeTurn case final turn?) {
        await client.request('turn/steer', {
          'threadId': thread,
          'expectedTurnId': turn,
          'input': input,
        });
        return;
      }
      _starting = true;
      _timing = {'started': DateTime.now(), 'tools': <String>[]};
      final r = await client.request('turn/start', {
        'threadId': thread,
        'input': input,
        'effort': ?_effort,
        'approvalPolicy': 'never',
        'sandboxPolicy': {'type': 'readOnly', 'networkAccess': false},
      }) as Map;
      activeTurn = (r['turn'] as Map)['id'] as String;
    } on RpcError catch (e) {
      entries.add(ChatEntry('error', '$e')..done = true);
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  Future<void> interrupt() async {
    final turn = activeTurn;
    if (turn == null) return;
    await _client?.request('turn/interrupt', {
      'threadId': threadId,
      'turnId': turn,
    });
  }

  void _onNotification(ServerNotification n) {
    final p = n.params;
    switch (n.method) {
      case 'turn/started':
        activeTurn = (p['turn'] as Map)['id'] as String;
      case 'turn/completed':
        final t = (p['turn'] as Map);
        activeTurn = null;
        if ((t['error'] as Map?)?['message'] case final String m) {
          entries.add(ChatEntry('error', m)..done = true);
        }
        if (_timing case final timing?) {
          timing['ended'] = DateTime.now();
          timing['status'] = t['status'];
          timings.add(timing);
          _log.add(_describeTiming(timing));
          debugPrint('[turn] ${_describeTiming(timing)}');
          _timing = null;
        }
      case 'item/agentMessage/delta':
        final id = p['itemId'] as String;
        final entry = _byItem.putIfAbsent(id, () {
          final e = ChatEntry('spirit', '');
          entries.add(e);
          return e;
        });
        entry.text += p['delta'] as String;
        onSpiritText?.call(entry);
      case 'item/completed':
        final item = (p['item'] as Map).cast<String, dynamic>();
        if (item['type'] == 'agentMessage') {
          final id = item['id'] as String;
          final entry = _byItem.putIfAbsent(id, () {
            final e = ChatEntry('spirit', '');
            entries.add(e);
            return e;
          });
          entry
            ..text = item['text'] as String? ?? entry.text
            ..done = true;
          onSpiritText?.call(entry);
        }
      case 'thread/tokenUsage/updated':
        _timing?['usage'] = p['tokenUsage'];
      case 'error':
        entries.add(ChatEntry('error', jsonEncode(p))..done = true);
      default:
        return;
    }
    notifyListeners();
  }

  String _describeTiming(Map<String, dynamic> t) {
    final started = t['started'] as DateTime;
    final first = t['first_tool'] as DateTime?;
    final ended = t['ended'] as DateTime;
    final total = ended.difference(started).inMilliseconds;
    return 'turn ${t['status']}: total ${total}ms'
        '${first != null ? ', first tool ${first.difference(started).inMilliseconds}ms' : ''}'
        ', tools ${(t['tools'] as List).join(' ')}';
  }

  Future<void> _onRequest(ServerRequest r) async {
    final client = _client!;
    if (r.method != 'item/tool/call') {
      client.respondError(r.id, -32000, 'not supported by this client');
      return;
    }
    final name = r.params['tool'] as String;
    final args = (r.params['arguments'] as Map? ?? const {})
        .cast<String, dynamic>();
    if (_timing case final t?) {
      t['first_tool'] ??= DateTime.now();
      (t['tools'] as List).add(name);
    }
    final entry = ChatEntry('tool', _shortArgs(args), tool: name);
    entries.add(entry);
    notifyListeners();
    ToolOutcome result;
    try {
      result = await onTool(name, args);
    } catch (e) {
      result = ToolOutcome('error: $e', ok: false);
    }
    entry
      ..text =
          '${_shortArgs(args)}\n→ ${result.text.length > 400 ? '${result.text.substring(0, 400)}…' : result.text}'
      ..done = true;
    notifyListeners();
    client.respond(r.id, {
      'contentItems': [
        {'type': 'inputText', 'text': result.text},
        for (final png in result.images)
          {'type': 'inputImage', 'imageUrl': 'data:image/png;base64,$png'},
      ],
      'success': result.ok,
    });
  }

  String _shortArgs(Map<String, dynamic> args) {
    final s = jsonEncode(args);
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }

  @override
  Future<void> dispose() async {
    await _logSink?.flush();
    await _logSink?.close();
    await _client?.dispose();
    super.dispose();
  }
}
