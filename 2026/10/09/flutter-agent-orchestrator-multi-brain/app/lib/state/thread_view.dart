import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../rpc/rpc_client.dart';

typedef Json = Map<String, dynamic>;

/// One transcript entry. [data] uses the item shapes the UI draws (the same
/// ones as the Codex lab: `userMessage`, `agentMessage`, `reasoning`,
/// `commandExecution`, `fileChange`, `mcpToolCall`, `webSearch`, `toolCall`),
/// filled in from the Agent SDK's messages.
class ItemState {
  ItemState(this.data) : startedAt = DateTime.now();

  Json data;
  final DateTime startedAt;
  bool completed = false;

  /// Streamed text (`text_delta` / `thinking_delta`).
  final text = StringBuffer();
  final output = StringBuffer();
  final reasoningSummary = <int, StringBuffer>{};

  String get id => data['id'] as String;
  String get type => data['type'] as String;

  String get displayText {
    final done = data['text'] as String?;
    if (done != null && done.isNotEmpty) return done;
    return text.toString();
  }

  String get commandOutput {
    final done = data['aggregatedOutput'] as String?;
    if (done != null) return done;
    return output.toString();
  }

  List<String> get reasoningParts {
    final done = (data['summary'] as List?)?.cast<String>();
    if (done != null && done.isNotEmpty) return done;
    // Codex streams summary parts by index; Claude streams thinking text.
    if (reasoningSummary.isNotEmpty) {
      final keys = reasoningSummary.keys.toList()..sort();
      return [for (final k in keys) reasoningSummary[k].toString()];
    }
    return [text.toString()];
  }
}

class TurnState {
  TurnState(this.id, {this.status = 'inProgress'});

  final String id;
  String status;
  String? error;
  int? durationMs;
  double? costUsd;
  final items = <ItemState>[];
  List<Json> plan = const [];
  String diff = '';

  ItemState? find(String itemId) {
    for (final i in items) {
      if (i.id == itemId) return i;
    }
    return null;
  }

  /// The SDK has no turn-level diff; join the turn's file changes.
  void buildDiff() {
    final parts = <String>[];
    for (final i in items.where((i) => i.type == 'fileChange')) {
      for (final c in (i.data['changes'] as List).cast<Map>()) {
        var diff = c['diff'] as String? ?? '';
        // `add` carries the file content; mark every line as added.
        if ((c['kind'] as Map?)?['type'] == 'add') {
          diff = const LineSplitter()
              .convert(diff)
              .map((l) => '+$l')
              .join('\n');
        }
        parts.add('diff --git a/${c['path']} b/${c['path']}\n$diff');
      }
    }
    diff = parts.join('\n');
  }
}

/// A permission prompt (`canUseTool`) waiting for the user.
class PendingRequest {
  PendingRequest(this.request);

  final ServerRequest request;
  String get method => request.method;
  Json get params => request.params;
}

/// The transcript of one agent thread, fed by either backend:
/// Every change goes through [apply] as a JSON operation and is kept in
/// [ops], so another app can rebuild the same transcript by applying the
/// same operations in order (see `mesh/`).
///
/// [handleCodexNotification] for `codex app-server` (server-side turn ids,
/// the user's message is echoed back as an item) or [handleSdkMessage] for
/// the Agent SDK (the app adds turns itself, see below).
///
/// Everything below about turns applies to the Agent SDK path.
///
/// Turns: the app adds a turn with the user's message when it sends one (the
/// SDK does not echo user input). SDK messages go to the oldest unfinished
/// turn, and each `result` finishes it. A message sent while a turn runs
/// (steer, `priority: "now"`) makes the SDK end that turn early
/// (`terminal_reason: aborted_tools`) and run the new message as the next
/// turn, which lines up with the turn the app already added.
class ThreadView extends ChangeNotifier {
  ThreadView({required this.threadId, required this.cwd, this.title});

  /// The Agent SDK session id.
  String threadId;
  String cwd;
  String? title;
  String? model;
  String? effort;
  String? permissionMode;
  final turns = <TurnState>[];
  final pending = <PendingRequest>[];

  /// Every operation applied so far, in order. Listeners read the ones past
  /// their cursor after each notification.
  final ops = <Json>[];

  /// `{modelContextWindow, last: {inputTokens}}`, the shape the composer's
  /// usage ring reads.
  Json? tokenUsage;
  final errors = <String>[];

  /// Set by the controller when the user presses stop, so the `result`
  /// that follows (an error subtype with a diagnostic text) reads as an
  /// interrupt rather than a failure.
  bool interruptRequested = false;

  /// Open assistant message: content block index -> item id.
  final _blocks = <int, String>{};
  String? _messageId;
  int _localTurns = 0;

  TurnState? get activeTurn {
    for (final t in turns) {
      if (t.status == 'inProgress') return t;
    }
    return null;
  }

  bool get isRunning => activeTurn != null;

  String get status => isRunning ? 'active' : 'idle';

  /// Applies one operation (from this app's backends, or replayed from
  /// another app) and notifies.
  void apply(Json op) {
    ops.add(op);
    switch (op['t']) {
      case 'user':
        _addUserTurn(op['text'] as String);
      case 'codex':
        _onCodexNotification(
          op['m'] as String,
          (op['p'] as Map).cast<String, dynamic>(),
        );
      case 'codexTurn':
        _codexTurn(op['id'] as String).status = 'inProgress';
      case 'sdk':
        _onSdkMessage((op['m'] as Map).cast<String, dynamic>());
      case 'interruptRequested':
        interruptRequested = true;
      case 'error':
        errors.add(op['text'] as String);
      case 'pendingAdd':
        pending.add(
          PendingRequest(
            ServerRequest(
              op['id'] as Object,
              op['method'] as String,
              (op['params'] as Map).cast<String, dynamic>(),
            ),
          ),
        );
      case 'pendingRemove':
        pending.removeWhere((r) => r.request.id == op['id']);
      case 'pendingCancel':
        pending.removeWhere((r) => r.params['requestId'] == op['requestId']);
      case 'image':
        _attachImage(op);
    }
    notifyListeners();
  }

  /// Adds a turn with the user's message (sent, or queued as steer).
  void addUserTurn(String text) => apply({'t': 'user', 'text': text});

  void _addUserTurn(String text) {
    final turn = TurnState('local-${_localTurns++}');
    turn.items.add(
      ItemState({
        'type': 'userMessage',
        'id': '${turn.id}:user',
        'content': [
          {'type': 'text', 'text': text},
        ],
      })..completed = true,
    );
    turns.add(turn);
  }

  TurnState _current() {
    final t = activeTurn;
    if (t != null) return t;
    // Output without a turn the app started (should not happen): add one.
    final turn = TurnState('local-${_localTurns++}');
    turns.add(turn);
    return turn;
  }

  // ---- codex app-server -----------------------------------------------------

  TurnState _codexTurn(String turnId) {
    for (final t in turns.reversed) {
      if (t.id == turnId) return t;
    }
    final t = TurnState(turnId);
    turns.add(t);
    return t;
  }

  ItemState? _codexItem(Json p) =>
      _codexTurn(p['turnId'] as String).find(p['itemId'] as String);

  /// Notifications for this thread from `codex app-server`.
  void handleCodexNotification(ServerNotification n) =>
      apply({'t': 'codex', 'm': n.method, 'p': n.params});

  void _onCodexNotification(String method, Json p) {
    switch (method) {
      case 'thread/name/updated':
        title = p['threadName'] as String? ?? title;
      case 'turn/started':
        final t = (p['turn'] as Map).cast<String, dynamic>();
        _codexTurn(t['id'] as String).status = 'inProgress';
      case 'turn/completed':
        final t = (p['turn'] as Map).cast<String, dynamic>();
        final turn = _codexTurn(t['id'] as String)
          ..status = t['status'] as String
          ..durationMs = (t['durationMs'] as num?)?.toInt()
          ..error = (t['error'] as Map?)?['message'] as String?;
        for (final i in turn.items) {
          i.completed = true;
        }
        pending.removeWhere((r) => r.params['turnId'] == turn.id);
      case 'item/started' || 'item/completed':
        final item = (p['item'] as Map).cast<String, dynamic>();
        final turn = _codexTurn(p['turnId'] as String);
        final existing = turn.find(item['id'] as String);
        final done = method == 'item/completed';
        if (existing == null) {
          turn.items.add(ItemState(item)..completed = done);
        } else {
          existing
            ..data = item
            ..completed = done || existing.completed;
        }
      case 'item/agentMessage/delta' || 'item/plan/delta':
        _codexItem(p)?.text.write(p['delta'] as String);
      case 'item/commandExecution/outputDelta':
        _codexItem(p)?.output.write(p['delta'] as String);
      case 'item/reasoning/summaryTextDelta':
        final item = _codexItem(p);
        if (item != null) {
          final index = (p['summaryIndex'] as num).toInt();
          item.reasoningSummary
              .putIfAbsent(index, StringBuffer.new)
              .write(p['delta'] as String);
        }
      case 'item/fileChange/patchUpdated':
        final item = _codexItem(p);
        if (item != null && p['changes'] != null) {
          item.data = {...item.data, 'changes': p['changes']};
        }
      case 'turn/plan/updated':
        _codexTurn(p['turnId'] as String).plan = (p['plan'] as List)
            .cast<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      case 'turn/diff/updated':
        _codexTurn(p['turnId'] as String).diff = p['diff'] as String;
      case 'thread/tokenUsage/updated':
        tokenUsage = (p['tokenUsage'] as Map).cast<String, dynamic>();
      case 'serverRequest/resolved':
        pending.removeWhere((r) => r.request.id == p['requestId']);
      case 'error':
        final e = (p['error'] as Map?)?['message'] as String? ?? 'error';
        errors.add('$e${p['willRetry'] == true ? ' (retrying)' : ''}');
    }
  }

  /// Marks a Codex turn as running right after `turn/start` returns, before
  /// its `turn/started` arrives.
  void startCodexTurn(String turnId) => apply({'t': 'codexTurn', 'id': turnId});

  // ---- Agent SDK --------------------------------------------------------------

  void handleSdkMessage(Json m) => apply({'t': 'sdk', 'm': m});

  void _onSdkMessage(Json m) {
    switch (m['type']) {
      case 'stream_event':
        _onStreamEvent((m['event'] as Map).cast<String, dynamic>());
      case 'assistant':
        _onAssistant(m, _current());
      case 'user':
        _onUser(m, _current());
      case 'result':
        _onResult(m);
      case 'system':
        // init, and status after a mode change (e.g. the user accepted the
        // "accept edits for this session" suggestion).
        if (m['subtype'] == 'init') model = m['model'] as String? ?? model;
        if (m['permissionMode'] case final String mode) permissionMode = mode;
    }
  }

  void _onStreamEvent(Json e) {
    final turn = _current();
    switch (e['type']) {
      case 'message_start':
        _messageId = (e['message'] as Map?)?['id'] as String?;
        _blocks.clear();
      case 'content_block_start':
        final index = (e['index'] as num).toInt();
        final block = (e['content_block'] as Map).cast<String, dynamic>();
        final item = _itemForBlockStart(block, index);
        if (item == null) return;
        _blocks[index] = item.id;
        if (turn.find(item.id) == null) turn.items.add(item);
      case 'content_block_delta':
        final id = _blocks[(e['index'] as num).toInt()];
        final item = id == null ? null : turn.find(id);
        final delta = (e['delta'] as Map).cast<String, dynamic>();
        switch (delta['type']) {
          case 'text_delta':
            item?.text.write(delta['text'] as String);
          case 'thinking_delta':
            item?.text.write(delta['thinking'] as String);
        }
      default:
        return;
    }
  }

  ItemState? _itemForBlockStart(Json block, int index) {
    final base = '${_messageId ?? 'msg'}:$index';
    return switch (block['type']) {
      'text' => ItemState({'type': 'agentMessage', 'id': base, 'text': ''}),
      'thinking' => ItemState({'type': 'reasoning', 'id': base}),
      'tool_use' => _toolItem(
        block['id'] as String,
        block['name'] as String,
        const {},
      ),
      _ => null,
    };
  }

  /// A complete assistant message: replaces the streamed parts. Claude Code
  /// sends one SDK message per content block (same API message id), so text
  /// and thinking are matched to the streamed item of the same kind that is
  /// still open, not by block index.
  void _onAssistant(Json m, TurnState turn) {
    final message = (m['message'] as Map).cast<String, dynamic>();
    final msgId = message['id'] as String? ?? _messageId ?? 'msg';
    final content = (message['content'] as List? ?? const []).cast<Map>();
    for (final raw in content) {
      final block = raw.cast<String, dynamic>();
      switch (block['type']) {
        case 'text':
          _completeBlock(turn, msgId, 'agentMessage', {'text': block['text']});
        case 'thinking':
          _completeBlock(turn, msgId, 'reasoning', {
            'summary': [block['thinking'] as String? ?? ''],
          });
        case 'tool_use':
          final name = block['name'] as String;
          final input = (block['input'] as Map? ?? const {})
              .cast<String, dynamic>();
          if (name == 'TodoWrite') {
            turn.plan = _planFromTodos(input);
          }
          final data = _toolItem(block['id'] as String, name, input).data;
          final existing = turn.find(data['id'] as String);
          if (existing == null) {
            turn.items.add(ItemState(data));
          } else {
            existing.data = {...existing.data, ...data};
          }
      }
    }
  }

  void _completeBlock(TurnState turn, String msgId, String type, Json fields) {
    ItemState? open;
    for (final i in turn.items) {
      if (!i.completed && i.type == type && i.id.startsWith('$msgId:')) {
        open = i;
        break;
      }
    }
    if (open == null) {
      final n = turn.items.where((i) => i.id.startsWith('$msgId:')).length;
      turn.items.add(
        ItemState({'type': type, 'id': '$msgId:c$n', ...fields})
          ..completed = true,
      );
    } else {
      open
        ..data = {...open.data, ...fields}
        ..completed = true;
    }
  }

  /// Tool results arrive as user messages with `tool_result` blocks.
  void _onUser(Json m, TurnState turn) {
    final content = (m['message'] as Map?)?['content'];
    if (content is! List) return;
    final structured = m['tool_use_result'];
    for (final b in content.cast<Map>()) {
      if (b['type'] != 'tool_result') continue;
      final item = turn.find(b['tool_use_id'] as String);
      if (item == null) continue;
      _completeTool(
        item,
        _resultText(b['content']),
        b['is_error'] == true,
        structured is Map ? structured.cast<String, dynamic>() : null,
      );
    }
  }

  void _onResult(Json m) {
    final turn = activeTurn;
    if (turn == null) return;
    final aborted =
        interruptRequested ||
        m['terminal_reason'] == 'aborted_tools' ||
        m['terminal_reason'] == 'aborted_streaming';
    final error =
        !interruptRequested &&
        (m['is_error'] == true || m['subtype'] != 'success');
    interruptRequested = false;
    turn
      ..status = error
          ? 'failed'
          : aborted
          ? 'interrupted'
          : 'completed'
      ..durationMs = (m['duration_ms'] as num?)?.toInt()
      ..costUsd = (m['total_cost_usd'] as num?)?.toDouble();
    if (error) {
      turn.error =
          (m['errors'] as List?)?.join('\n') ??
          m['result'] as String? ??
          m['subtype'] as String?;
    }
    for (final i in turn.items) {
      if (!i.completed && i.type != 'userMessage') {
        // A tool cut short by an interrupt or a steer.
        if (i.data['status'] == 'inProgress') {
          i.data = {...i.data, 'status': aborted ? 'declined' : 'completed'};
        }
        i.completed = true;
      }
    }
    turn.buildDiff();
    pending.clear();
  }

  // ---- tools ----------------------------------------------------------------

  /// Maps a Claude Code tool call onto the UI's item shapes.
  ItemState _toolItem(String id, String name, Json input) {
    final Json data;
    if (name == 'Bash') {
      data = {
        'type': 'commandExecution',
        'id': id,
        'command': input['command'] ?? '',
        'status': 'inProgress',
        'commandActions': const [],
      };
    } else if (const {
      'Edit',
      'MultiEdit',
      'Write',
      'NotebookEdit',
    }.contains(name)) {
      final path =
          (input['file_path'] ?? input['notebook_path'] ?? '') as String;
      data = {
        'type': 'fileChange',
        'id': id,
        'status': 'inProgress',
        'changes': [
          {
            'path': path,
            'kind': {'type': name == 'Write' ? 'add' : 'update'},
            'diff': _diffFromInput(name, input),
          },
        ],
      };
    } else if (name.startsWith('mcp__')) {
      final parts = name.split('__');
      data = {
        'type': 'mcpToolCall',
        'id': id,
        'server': parts.length > 1 ? parts[1] : 'mcp',
        'tool': parts.length > 2 ? parts.sublist(2).join('__') : name,
        'arguments': input,
        'status': 'inProgress',
      };
    } else if (name == 'WebSearch') {
      data = {'type': 'webSearch', 'id': id, 'query': input['query'] ?? ''};
    } else {
      data = {
        'type': 'toolCall',
        'id': id,
        'tool': name,
        'label': _toolLabel(name, input),
        'arguments': input,
        'status': 'inProgress',
      };
    }
    return ItemState(data);
  }

  void _completeTool(
    ItemState item,
    String text,
    bool isError,
    Json? structured,
  ) {
    final status = isError ? 'failed' : 'completed';
    switch (item.type) {
      case 'commandExecution':
        final stdout = structured?['stdout'] as String?;
        final stderr = structured?['stderr'] as String?;
        final out = stdout == null
            ? text
            : [
                stdout,
                if (stderr != null && stderr.isNotEmpty) stderr,
              ].join('\n');
        item.data = {
          ...item.data,
          'aggregatedOutput': out,
          'status': status,
          if (isError) 'exitCode': 1,
        };
      case 'fileChange':
        final patch = structured?['structuredPatch'];
        final changes = (item.data['changes'] as List).cast<Map>();
        if (patch is List && patch.isNotEmpty && changes.isNotEmpty) {
          final isCreate = structured?['type'] == 'create';
          item.data = {
            ...item.data,
            'changes': [
              {
                ...changes.first,
                if (!isCreate) 'kind': {'type': 'update'},
                if (!isCreate) 'diff': _diffFromPatch(patch),
              },
            ],
          };
        }
        item.data = {...item.data, 'status': status};
      case 'mcpToolCall' || 'toolCall':
        item.data = {
          ...item.data,
          'status': status,
          if (isError) 'error': {'message': text} else 'result': text,
        };
    }
    item.completed = true;
  }

  static String _resultText(Object? content) {
    if (content is String) return content;
    if (content is List) {
      return content
          .whereType<Map>()
          .map(
            (c) => c['type'] == 'text' ? c['text'] as String : '[${c['type']}]',
          )
          .join('\n');
    }
    return '';
  }

  static String _diffFromPatch(List patch) {
    final b = StringBuffer();
    for (final h in patch.cast<Map>()) {
      b.writeln(
        '@@ -${h['oldStart']},${h['oldLines']} +${h['newStart']},${h['newLines']} @@',
      );
      for (final line in (h['lines'] as List).cast<String>()) {
        b.writeln(line);
      }
    }
    return b.toString();
  }

  /// Before the result (and in history) only the input is known.
  static String _diffFromInput(String name, Json input) {
    String minus(String s) =>
        const LineSplitter().convert(s).map((l) => '-$l').join('\n');
    String plus(String s) =>
        const LineSplitter().convert(s).map((l) => '+$l').join('\n');
    switch (name) {
      case 'Write':
        // `add` changes carry the content; the UI prefixes it with '+'.
        return input['content'] as String? ?? '';
      case 'Edit':
        return '${minus(input['old_string'] as String? ?? '')}\n${plus(input['new_string'] as String? ?? '')}';
      case 'MultiEdit':
        return (input['edits'] as List? ?? const [])
            .cast<Map>()
            .map(
              (e) =>
                  '${minus(e['old_string'] as String? ?? '')}\n${plus(e['new_string'] as String? ?? '')}',
            )
            .join('\n');
      default:
        return '';
    }
  }

  static String _toolLabel(String name, Json input) {
    String? s(String k) => input[k] as String?;
    return switch (name) {
      'Read' => 'Read ${s('file_path') ?? ''}',
      'Glob' => 'Glob ${s('pattern') ?? ''}',
      'Grep' =>
        'Grep ${s('pattern') ?? ''}${s('path') != null ? ' in ${s('path')}' : ''}',
      'WebFetch' => 'Fetched ${s('url') ?? ''}',
      'Task' || 'Agent' => 'Agent: ${s('description') ?? ''}',
      'TodoWrite' => 'Updated the plan',
      'Skill' => 'Skill ${s('skill') ?? ''}',
      'ToolSearch' => 'Searched tools ${s('query') ?? ''}',
      _ => name,
    };
  }

  static List<Json> _planFromTodos(Json input) {
    return (input['todos'] as List? ?? const []).cast<Map>().map((t) {
      return <String, dynamic>{
        'step': t['content'] ?? '',
        'status': switch (t['status']) {
          'completed' => 'completed',
          'in_progress' => 'inProgress',
          _ => 'pending',
        },
      };
    }).toList();
  }

  void addError(String text) => apply({'t': 'error', 'text': text});

  /// An image the app attached to the conversation (one the orchestrator
  /// fetched from a body): `{body, path, mime, data (base64), width,
  /// height}`. Shown in the transcript; it travels to every console with the
  /// other operations.
  void attachImage(Json image) => apply({
    't': 'image',
    'id': 'image-${ops.where((o) => o['t'] == 'image').length}',
    ...image,
  });

  void _attachImage(Json op) {
    final turn = activeTurn ?? turns.lastOrNull ?? _current();
    turn.items.add(
      ItemState({
        'type': 'imageAttachment',
        'id': op['id'],
        'body': op['body'],
        'path': op['path'],
        'mime': op['mime'],
        'data': op['data'],
        'width': op['width'],
        'height': op['height'],
      })..completed = true,
    );
  }

  /// Set when the user presses stop (see [interruptRequested]).
  void requestInterrupt() => apply({'t': 'interruptRequested'});

  // ---- permissions ----------------------------------------------------------

  void addPending(ServerRequest r) => apply({
    't': 'pendingAdd',
    'id': r.id,
    'method': r.method,
    'params': r.params,
  });

  void removePending(PendingRequest r) =>
      apply({'t': 'pendingRemove', 'id': r.request.id});

  void cancelPending(String requestId) =>
      apply({'t': 'pendingCancel', 'requestId': requestId});
}
