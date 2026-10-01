import 'package:flutter/foundation.dart';

import '../codex/app_server_client.dart';

typedef Json = Map<String, dynamic>;

/// One `ThreadItem`, kept as the raw JSON from the server plus the text that
/// streamed in before `item/completed` arrived.
class ItemState {
  ItemState(this.data) : startedAt = DateTime.now();

  Json data;
  final DateTime startedAt;
  bool completed = false;

  /// `item/agentMessage/delta`, `item/plan/delta`.
  final text = StringBuffer();

  /// `item/commandExecution/outputDelta`.
  final output = StringBuffer();

  /// `item/reasoning/summaryTextDelta` by summaryIndex.
  final reasoningSummary = <int, StringBuffer>{};

  String get id => data['id'] as String;
  String get type => data['type'] as String;

  /// Text to show: the completed text when the server sent one, otherwise the
  /// streamed deltas.
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
    final keys = reasoningSummary.keys.toList()..sort();
    return [for (final k in keys) reasoningSummary[k].toString()];
  }
}

class TurnState {
  TurnState(this.id, {this.status = 'inProgress'});

  final String id;
  String status;
  String? error;
  int? durationMs;
  final items = <ItemState>[];
  List<Json> plan = const [];
  String diff = '';

  ItemState? find(String itemId) {
    for (final i in items) {
      if (i.id == itemId) return i;
    }
    return null;
  }
}

/// A pending server request (approval / user input) for this thread.
class PendingRequest {
  PendingRequest(this.request);

  final ServerRequest request;
  String get method => request.method;
  Json get params => request.params;
}

/// Everything the transcript needs for the open thread.
class ThreadView extends ChangeNotifier {
  ThreadView({required this.threadId, required this.cwd, this.title});

  final String threadId;
  String cwd;
  String? title;
  String? model;
  String? effort;
  String status = 'idle';
  final turns = <TurnState>[];
  final pending = <PendingRequest>[];
  Json? tokenUsage;
  final errors = <String>[];

  TurnState? get activeTurn {
    for (final t in turns.reversed) {
      if (t.status == 'inProgress') return t;
    }
    return null;
  }

  bool get isRunning => activeTurn != null;

  /// Builds the view from `thread/resume` / `thread/read` (turns with items).
  void loadTurns(List<dynamic> rawTurns) {
    turns.clear();
    for (final raw in rawTurns.cast<Map>()) {
      final t = raw.cast<String, dynamic>();
      final turn = TurnState(t['id'] as String, status: t['status'] as String)
        ..durationMs = (t['durationMs'] as num?)?.toInt()
        ..error = (t['error'] as Map?)?['message'] as String?;
      for (final item in (t['items'] as List? ?? const []).cast<Map>()) {
        turn.items.add(
          ItemState(item.cast<String, dynamic>())..completed = true,
        );
      }
      turns.add(turn);
    }
    notifyListeners();
  }

  TurnState _turn(String turnId) {
    for (final t in turns.reversed) {
      if (t.id == turnId) return t;
    }
    final t = TurnState(turnId);
    turns.add(t);
    return t;
  }

  ItemState? _item(Json p) {
    final turn = _turn(p['turnId'] as String);
    return turn.find(p['itemId'] as String);
  }

  void handleNotification(ServerNotification n) {
    final p = n.params;
    switch (n.method) {
      case 'thread/status/changed':
        status = (p['status'] as Map)['type'] as String;
      case 'thread/name/updated':
        title = p['threadName'] as String? ?? title;
      case 'turn/started':
        final t = (p['turn'] as Map).cast<String, dynamic>();
        _turn(t['id'] as String).status = 'inProgress';
      case 'turn/completed':
        final t = (p['turn'] as Map).cast<String, dynamic>();
        final turn = _turn(t['id'] as String)
          ..status = t['status'] as String
          ..durationMs = (t['durationMs'] as num?)?.toInt()
          ..error = (t['error'] as Map?)?['message'] as String?;
        for (final i in turn.items) {
          i.completed = true;
        }
        pending.removeWhere((r) => r.params['turnId'] == turn.id);
      case 'item/started':
        final item = (p['item'] as Map).cast<String, dynamic>();
        final turn = _turn(p['turnId'] as String);
        final existing = turn.find(item['id'] as String);
        if (existing == null) {
          turn.items.add(ItemState(item));
        } else {
          existing.data = item;
        }
      case 'item/completed':
        final item = (p['item'] as Map).cast<String, dynamic>();
        final turn = _turn(p['turnId'] as String);
        final existing = turn.find(item['id'] as String);
        if (existing == null) {
          turn.items.add(ItemState(item)..completed = true);
        } else {
          existing
            ..data = item
            ..completed = true;
        }
      case 'item/agentMessage/delta' || 'item/plan/delta':
        _item(p)?.text.write(p['delta'] as String);
      case 'item/commandExecution/outputDelta':
        _item(p)?.output.write(p['delta'] as String);
      case 'item/reasoning/summaryTextDelta':
        final item = _item(p);
        if (item != null) {
          final index = (p['summaryIndex'] as num).toInt();
          item.reasoningSummary
              .putIfAbsent(index, StringBuffer.new)
              .write(p['delta'] as String);
        }
      case 'item/fileChange/patchUpdated':
        final item = _item(p);
        if (item != null && p['changes'] != null) {
          item.data = {...item.data, 'changes': p['changes']};
        }
      case 'turn/plan/updated':
        _turn(p['turnId'] as String).plan = (p['plan'] as List)
            .cast<Map>()
            .map((e) => e.cast<String, dynamic>())
            .toList();
      case 'turn/diff/updated':
        _turn(p['turnId'] as String).diff = p['diff'] as String;
      case 'thread/tokenUsage/updated':
        tokenUsage = (p['tokenUsage'] as Map).cast<String, dynamic>();
      case 'serverRequest/resolved':
        final id = p['requestId'];
        pending.removeWhere((r) => r.request.id == id);
      case 'error':
        final e = (p['error'] as Map?)?['message'] as String? ?? 'error';
        final retry = p['willRetry'] == true ? ' (retrying)' : '';
        errors.add('$e$retry');
      default:
        return;
    }
    notifyListeners();
  }

  void addPending(ServerRequest r) {
    pending.add(PendingRequest(r));
    notifyListeners();
  }

  void removePending(PendingRequest r) {
    pending.remove(r);
    notifyListeners();
  }
}
