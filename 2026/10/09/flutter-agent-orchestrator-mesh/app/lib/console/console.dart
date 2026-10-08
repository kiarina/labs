import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../agents/agent_thread.dart';
import '../body/body.dart';
import '../mesh/peer.dart';
import '../orchestrator/hub.dart';
import '../rpc/rpc_client.dart';
import '../state/thread_view.dart';

// The brain is the only source of truth. It sends every console the same
// messages (`t: console`): a snapshot when the console joins, then the hub
// state when it changes and each thread's new transcript operations. Every
// app's console, the brain's own included, draws only what it received.

int? _ms(DateTime? t) => t?.millisecondsSinceEpoch;
DateTime? _time(Object? ms) => ms == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch((ms as num).toInt());

/// The brain's side: turns the hub into console messages.
class ConsolePublisher {
  ConsolePublisher(this.hub) {
    hub.addListener(_schedule);
  }

  final Hub hub;
  final _subscribers = <Peer>[];
  final _keys = <AgentThread, String>{};
  final _sent = <AgentThread, int>{};
  int _seq = 0;
  String? _lastState;
  Timer? _timer;

  /// Messages sent to consoles since start, for the README's numbers.
  int messages = 0;

  void _schedule() {
    // Streaming text arrives in many small deltas; batch them.
    _timer ??= Timer(const Duration(milliseconds: 30), flush);
  }

  List<AgentThread> get _threads => [?hub.orchestrator, ...hub.workers];

  String _key(AgentThread t) => _keys.putIfAbsent(t, () {
    t.view.addListener(_schedule);
    _sent[t] = 0;
    return t.label == 'orchestrator' ? 'o${++_seq}' : t.label;
  });

  Json _meta(AgentThread t) => {
    'key': _key(t),
    'label': t.label,
    'body': t.body,
    'provider': t.provider.name,
    'cwd': t.cwd,
    'title': t.title,
    'model': t.model,
    'state': t.state.name,
    'createdAt': _ms(t.createdAt),
    'turnStartedAt': _ms(t.turnStartedAt),
    'finishedAt': _ms(t.finishedAt),
  };

  Json _state() => {
    'brain': hub.local.name,
    'ready': hub.ready,
    'startupError': hub.startupError,
    'projectDir': hub.projectDir,
    'settings': hub.settings.toJson(),
    'orchestrator': hub.orchestrator == null ? null : _key(hub.orchestrator!),
    'workers': [for (final w in hub.workers) _key(w)],
    'threads': [for (final t in _threads) _meta(t)],
    'bodies': [
      for (final b in hub.bodies.values)
        {
          ...b.info,
          'name': b.name,
          'online': b.online,
          'isBrain': b.isLocal,
          'running': hub.runningOn(b.name),
        },
    ],
  };

  void _broadcast(Json m) {
    messages++;
    for (final s in _subscribers) {
      s.send({'t': 'console', 'm': m});
    }
  }

  /// Sends what changed since the last flush.
  void flush() {
    _timer?.cancel();
    _timer = null;
    final state = _state();
    final encoded = jsonEncode(state);
    if (encoded != _lastState) {
      _lastState = encoded;
      _broadcast({'k': 'state', 'state': state});
    }
    for (final t in _threads) {
      final ops = t.view.ops;
      final from = _sent[t]!;
      if (ops.length == from) continue;
      _sent[t] = ops.length;
      _broadcast({
        'k': 'ops',
        'key': _key(t),
        'from': from,
        'ops': ops.sublist(from),
      });
    }
  }

  /// A console joins: catch everyone up, then send it everything so far.
  void subscribe(Peer peer) {
    flush();
    peer.send({
      't': 'console',
      'm': {
        'k': 'snapshot',
        'state': _state(),
        'ops': {for (final t in _threads) _key(t): t.view.ops},
      },
    });
    _subscribers.add(peer);
    peer.closed.then((_) => _subscribers.remove(peer));
  }
}

/// A thread as a console sees it: the brain's metadata and a transcript
/// rebuilt from its operations.
class ThreadMirror {
  ThreadMirror(Json meta)
    : key = meta['key'] as String,
      label = meta['label'] as String,
      body = meta['body'] as String,
      provider = Provider.parse(meta['provider'] as String),
      cwd = meta['cwd'] as String,
      createdAt = _time(meta['createdAt'])!,
      view = ThreadView(threadId: '', cwd: meta['cwd'] as String) {
    update(meta);
  }

  final String key;
  final String label;
  final String body;
  final Provider provider;
  final String cwd;
  final DateTime createdAt;
  final ThreadView view;
  String? title;
  String? model;
  AgentState state = AgentState.queued;
  DateTime? turnStartedAt;
  DateTime? finishedAt;

  bool get isRunning => state == AgentState.running;

  void update(Json meta) {
    title = meta['title'] as String?;
    model = meta['model'] as String?;
    state = AgentState.values.byName(meta['state'] as String);
    turnStartedAt = _time(meta['turnStartedAt']);
    finishedAt = _time(meta['finishedAt']);
  }

  /// Operations that failed to apply or arrived after a gap (should stay
  /// empty; for `ORCH_DUMP`).
  final problems = <String>[];

  void applyOps(int from, List<dynamic> ops) {
    for (var i = 0; i < ops.length; i++) {
      // A batch that overlaps what the snapshot already had.
      if (from + i < view.ops.length) continue;
      if (from + i > view.ops.length) {
        problems.add('gap: batch from ${from + i}, have ${view.ops.length}');
        return;
      }
      final op = (ops[i] as Map).cast<String, dynamic>();
      try {
        view.apply(op);
      } catch (e, st) {
        problems.add(
          'op ${from + i} (${op['t']} ${op['m'] is String ? op['m'] : (op['m'] as Map?)?['type'] ?? ''}): $e '
          '${st.toString().split('\n').take(3).join(' | ')}',
        );
      }
    }
  }
}

/// What one body looks like in the console.
class BodyView {
  BodyView(this.info);

  final Json info;
  String get name => info['name'] as String;
  String get host => info['host'] as String? ?? '';
  bool get online => info['online'] == true;
  bool get isBrain => info['isBrain'] == true;
  int get running => (info['running'] as num?)?.toInt() ?? 0;
  List<Provider> get providers => [
    for (final p in info['providers'] as List? ?? const [])
      Provider.parse(p as String),
  ];
  String get projectDir => info['projectDir'] as String? ?? '';
  List<String> get usage => [
    for (final v in (info['usage'] as Map? ?? const {}).values) '$v',
  ];
  List<Json> modelsFor(Provider p) =>
      ((info['models'] as Map?)?[p.name] as List? ?? const [])
          .cast<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
  String? defaultModel(Provider p) =>
      (info['defaultModels'] as Map?)?[p.name] as String?;
  String? get kiapiError => info['kiapiError'] as String?;
}

/// Every app's console reads this. It holds what the brain sent, and sends
/// the user's actions back to the brain.
class ConsoleMirror extends ChangeNotifier {
  ConsoleMirror({required this.local, required this.isBrain});

  /// This app's own backends (for its name and its protocol log).
  final LocalBody local;

  /// Whether this app is the brain.
  final bool isBrain;

  String get selfName => local.name;

  /// How the console reaches the brain (an in-process call on the brain).
  void Function(Json action)? sendAction;

  /// "connecting to …", "connected", or why not.
  String link = 'starting';

  bool connected = false;
  Json _state = const {};
  final threads = <String, ThreadMirror>{};
  final settings = HubSettings();

  /// The thread shown in the center (local to this console).
  ThreadMirror? viewing;

  String get brain => _state['brain'] as String? ?? '';
  bool get ready => connected && _state['ready'] == true;
  String? get startupError => _state['startupError'] as String?;
  String get projectDir => _state['projectDir'] as String? ?? '';

  ThreadMirror? get orchestrator => threads[_state['orchestrator']];

  List<ThreadMirror> get workers => [
    for (final k in _state['workers'] as List? ?? const []) ?threads[k],
  ];

  List<BodyView> get bodies => [
    for (final b in (_state['bodies'] as List? ?? const []).cast<Map>())
      BodyView(b.cast<String, dynamic>()),
  ];

  BodyView? get brainBody => bodies.where((b) => b.isBrain).firstOrNull;

  /// Providers the orchestrator can use (the brain's).
  List<Provider> get providers => brainBody?.providers ?? const [];

  List<Json> modelsFor(Provider p) => brainBody?.modelsFor(p) ?? const [];

  String? defaultModelFor(Provider p) =>
      settings.workerModel[p] ?? brainBody?.defaultModel(p);

  int get runningCount => workers.where((w) => w.isRunning).length;

  List<ProtocolLogEntry> get protocolLog => local.protocolLog;

  void handle(Json m) {
    switch (m['k']) {
      case 'snapshot':
        threads.clear();
        viewing = null;
        _setState((m['state'] as Map).cast<String, dynamic>());
        for (final e in (m['ops'] as Map).entries) {
          threads[e.key]?.applyOps(0, e.value as List);
        }
      case 'state':
        _setState((m['state'] as Map).cast<String, dynamic>());
      case 'ops':
        threads[m['key']]?.applyOps(
          (m['from'] as num).toInt(),
          m['ops'] as List,
        );
        return; // The thread's view notifies its own listeners.
    }
    notifyListeners();
  }

  void _setState(Json s) {
    _state = s;
    settings.load((s['settings'] as Map).cast<String, dynamic>());
    final seen = <String>{};
    for (final raw in (s['threads'] as List).cast<Map>()) {
      final meta = raw.cast<String, dynamic>();
      final key = meta['key'] as String;
      seen.add(key);
      final t = threads[key];
      if (t == null) {
        threads[key] = ThreadMirror(meta);
      } else {
        t.update(meta);
      }
    }
    threads.removeWhere((k, _) => !seen.contains(k));
    if (viewing != null && !threads.containsValue(viewing)) viewing = null;
  }

  /// Link changes with the time since start, for the README's numbers.
  final linkLog = <String>[];
  final _clock = Stopwatch()..start();

  void _logLink() {
    linkLog.add(
      '${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s $link',
    );
    if (linkLog.length > 80) linkLog.removeAt(0);
  }

  /// A step of connecting (for the link log only).
  void logStep(String step) {
    linkLog.add(
      '${(_clock.elapsedMilliseconds / 1000).toStringAsFixed(1)}s   $step',
    );
    if (linkLog.length > 80) linkLog.removeAt(0);
  }

  void onDisconnected(String why) {
    connected = false;
    link = why;
    _logLink();
    notifyListeners();
  }

  void onConnected(String how) {
    connected = true;
    link = how;
    _logLink();
    notifyListeners();
  }

  // ---- actions (to the brain) -------------------------------------------------

  void _act(Json a) => sendAction?.call(a);

  Future<void> sendToOrchestrator(String text) async {
    viewing = null;
    notifyListeners();
    _act({'a': 'send', 'text': text});
  }

  void interruptOrchestrator() => _act({'a': 'interrupt'});

  Future<void> newConversation({Provider? provider}) async {
    viewing = null;
    _act({'a': 'new', 'provider': provider?.name});
  }

  void stopWorker(ThreadMirror w) => _act({'a': 'stop', 'id': w.label});

  void answer(PendingRequest r, Object? result) =>
      _act({'a': 'answer', 'requestId': r.request.id, 'result': result});

  /// Sends edited settings (the brain saves them).
  void saveSettings(HubSettings s) =>
      _act({'a': 'settings', 'settings': s.toJson()});

  /// Only the brain's console can pick a folder: the path is on its machine.
  void setProject(String dir) => _act({'a': 'project', 'dir': dir});

  void view(ThreadMirror? t) {
    viewing = t;
    notifyListeners();
  }

  /// What this console shows, for comparing consoles (`ORCH_DUMP`): the
  /// threads, their transcripts' last answers, and a hash of every
  /// transcript operation.
  Json digest() => {
    'self': selfName,
    'isBrain': isBrain,
    'connected': connected,
    'link': link,
    'linkLog': linkLog,
    'brain': brain,
    'bodies': [
      for (final b in bodies)
        {'name': b.name, 'online': b.online, 'running': b.running},
    ],
    'orchestrator': orchestrator?.key,
    'threads': [
      for (final t in threads.values)
        {
          'key': t.key,
          'body': t.body,
          'provider': t.provider.name,
          'state': t.state.name,
          'turns': t.view.turns.length,
          'ops': t.view.ops.length,
          'opsHash': fnv1a(jsonEncode(t.view.ops)),
          'problems': t.problems.take(5).toList(),
          'images': [
            for (final turn in t.view.turns)
              for (final i in turn.items)
                if (i.type == 'imageAttachment')
                  {
                    'body': i.data['body'],
                    'path': i.data['path'],
                    'size': '${i.data['width']}x${i.data['height']}',
                    'hash': fnv1a(i.data['data'] as String),
                  },
          ],
          'lastAnswer': _lastAnswer(t.view),
        },
    ],
  };

  static String _lastAnswer(ThreadView v) {
    for (final turn in v.turns.reversed) {
      for (final item in turn.items.reversed) {
        if (item.type == 'agentMessage' && item.displayText.trim().isNotEmpty) {
          return item.displayText;
        }
      }
    }
    return '';
  }
}

/// 32-bit FNV-1a over UTF-16 code units, as hex.
String fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
