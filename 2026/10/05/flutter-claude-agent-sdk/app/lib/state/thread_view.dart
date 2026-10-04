import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../claude/bridge_client.dart';

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

/// Everything the transcript needs for the open session.
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
  final String threadId;
  String cwd;
  String? title;
  String? model;
  String? effort;
  String? permissionMode;
  final turns = <TurnState>[];
  final pending = <PendingRequest>[];

  /// `{modelContextWindow, last: {inputTokens}}`, the shape the composer's
  /// usage ring reads.
  Json? tokenUsage;
  final errors = <String>[];

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

  /// Adds a turn with the user's message (sent, or queued as steer).
  void addUserTurn(String text) {
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
    notifyListeners();
  }

  TurnState _current() {
    final t = activeTurn;
    if (t != null) return t;
    // Output without a turn the app started (should not happen): add one.
    final turn = TurnState('local-${_localTurns++}');
    turns.add(turn);
    return turn;
  }

  // ---- live messages --------------------------------------------------------

  void handleSdkMessage(Json m) {
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
      default:
        return;
    }
    notifyListeners();
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
        m['terminal_reason'] == 'aborted_tools' ||
        m['terminal_reason'] == 'aborted_streaming';
    final error = m['is_error'] == true || m['subtype'] != 'success';
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

  // ---- history --------------------------------------------------------------

  /// Rebuilds the transcript from `getSessionMessages()`. History has the raw
  /// API messages only (no results, no structured tool output), so a new turn
  /// starts at each user text message and every turn shows as completed.
  void loadHistory(List<dynamic> messages) {
    turns.clear();
    TurnState? turn;
    for (final raw in messages.cast<Map>()) {
      final m = raw.cast<String, dynamic>();
      final message = (m['message'] as Map?)?.cast<String, dynamic>();
      if (message == null) continue;
      final content = message['content'];
      if (m['type'] == 'user') {
        final text = content is String
            ? content
            : (content as List)
                  .whereType<Map>()
                  .where((b) => b['type'] == 'text')
                  .map((b) => b['text'] as String)
                  .join('\n');
        final hasToolResult =
            content is List &&
            content.any((b) => b is Map && b['type'] == 'tool_result');
        if (text.trim().isNotEmpty && !hasToolResult && !_isMeta(text)) {
          turn?.status = 'completed';
          turn?.buildDiff();
          addUserTurn(text);
          turn = turns.last;
        } else if (turn != null && hasToolResult) {
          _onUser({'message': message}, turn);
        }
      } else if (m['type'] == 'assistant' && turn != null) {
        _onAssistant({'message': message}, turn);
      }
    }
    for (final t in turns) {
      t.status = 'completed';
      for (final i in t.items) {
        i.completed = true;
      }
      t.buildDiff();
    }
    notifyListeners();
  }

  /// Claude Code stores some injected context as user messages.
  static bool _isMeta(String text) {
    final t = text.trimLeft();
    return t.startsWith('<command-') ||
        t.startsWith('<local-command') ||
        t.startsWith('<system-reminder>') ||
        t.startsWith('Caveat:');
  }

  /// Repaints after the controller changed fields (title, usage).
  void refresh() => notifyListeners();

  // ---- permissions ----------------------------------------------------------

  void addPending(ServerRequest r) {
    pending.add(PendingRequest(r));
    notifyListeners();
  }

  void removePending(PendingRequest r) {
    pending.remove(r);
    notifyListeners();
  }

  void cancelPending(String requestId) {
    pending.removeWhere((p) => p.params['requestId'] == requestId);
    notifyListeners();
  }
}
