import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../agents/agent_thread.dart';
import '../body/body.dart';
import '../mesh/peer.dart';
import '../mesh/signal.dart';
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
    'workerType': t.workerType,
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
          'owner': hub.ownerOf(b.name),
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
      workerType = meta['workerType'] as String,
      cwd = meta['cwd'] as String,
      createdAt = _time(meta['createdAt'])!,
      view = ThreadView(threadId: '', cwd: meta['cwd'] as String) {
    update(meta);
  }

  final String key;
  final String label;
  final String body;
  final String workerType;
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

  /// Paused by its owner: its brain starts nothing new there.
  bool get paused => info['paused'] == true;

  /// Every worker type the body offers, available or not (`error`).
  List<Json> get workerTypeInfo => [
    for (final t in info['workerTypes'] as List? ?? const [])
      (t as Map).cast<String, dynamic>(),
  ];
  List<String> get workerTypes => [
    for (final t in workerTypeInfo)
      if (t['error'] == null) t['id'] as String,
  ];
  String labelOf(String id) =>
      workerTypeInfo.where((t) => t['id'] == id).firstOrNull?['label'] as String? ?? id;
  String? get typeConfigError => info['typeConfigError'] as String?;
  String get projectDir => info['projectDir'] as String? ?? '';
  int? get maxWorkers => (info['maxWorkers'] as num?)?.toInt();
  List<String> get usage => [
    for (final v in (info['usage'] as Map? ?? const {}).values) '$v',
  ];
  List<Json> modelsFor(String type) =>
      ((info['models'] as Map?)?[type] as List? ?? const [])
          .cast<Map>()
          .map((m) => m.cast<String, dynamic>())
          .toList();
  String? defaultModel(String type) =>
      (info['defaultModels'] as Map?)?[type] as String?;
}

/// What the console shows of one brain: the state and threads that brain
/// sent, and how to send that brain the user's actions.
class BrainView {
  BrainView(this.name, this.send);

  final String name;
  final void Function(Json action) send;
  Json state = const {};
  final threads = <String, ThreadMirror>{};
  final settings = HubSettings();
  bool get synced => state.isNotEmpty;

  /// Returns whether the console needs a repaint (ops repaint their thread).
  bool handle(Json m) {
    switch (m['k']) {
      case 'snapshot':
        threads.clear();
        _setState((m['state'] as Map).cast<String, dynamic>());
        for (final e in (m['ops'] as Map).entries) {
          threads[e.key]?.applyOps(0, e.value as List);
        }
      case 'state':
        _setState((m['state'] as Map).cast<String, dynamic>());
      case 'ops':
        threads[m['key']]?.applyOps((m['from'] as num).toInt(), m['ops'] as List);
        return false;
    }
    return true;
  }

  void _setState(Json s) {
    state = s;
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
  }

  ThreadMirror? get orchestrator => threads[state['orchestrator']];

  List<ThreadMirror> get workers => [
    for (final k in state['workers'] as List? ?? const []) ?threads[k],
  ];

  List<BodyView> get bodies => [
    for (final b in (state['bodies'] as List? ?? const []).cast<Map>())
      BodyView(b.cast<String, dynamic>()),
  ];

  Json digest() => {
    'orchestrator': orchestrator?.key,
    'threads': [
      for (final t in threads.values)
        {
          'key': t.key,
          'body': t.body,
          'workerType': t.workerType,
          'state': t.state.name,
          'turns': t.view.turns.length,
          'turnStates': [for (final u in t.view.turns) '${u.id}:${u.status}'],
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

/// One app in the console's body list: the roster's record, who owns it,
/// and what a brain knows about it (worker types, usage).
class BodyEntry {
  BodyEntry(this.node, this.owner, this.view, this.running);

  final SignalNode node;
  final String? owner;
  final BodyView? view;

  /// Workers of its owner running there.
  final int running;
  String get name => node.name;
}

/// Every app's console reads this. It mirrors every brain this app is
/// linked to and shows the selected one; actions go to the selected brain.
/// Body ownership goes through the signaling server.
class ConsoleMirror extends ChangeNotifier {
  ConsoleMirror({required this.local, required this.signal, required this.isBrain}) {
    signal.addListener(notifyListeners);
  }

  /// This app's own backends (for its protocol log).
  final LocalBody local;
  final SignalClient signal;

  /// Whether this app is a brain.
  final bool isBrain;

  /// Whether this app runs the signaling server.
  bool signaling = false;

  /// What this app is, for the header: "brain · body · signal", "console".
  String get roles {
    final r = [if (isBrain) 'brain', if (signal.isBody) 'body', if (signaling) 'signal'];
    return r.isEmpty ? 'console' : r.join(' · ');
  }

  final views = <String, BrainView>{};
  String? selected;

  /// The brain to show first (`ORCH_SELECT`), when it is linked.
  String? preferred;

  /// The last message about moving a body (shown in the body list).
  String? notice;

  /// The thread shown in the center (local to this console).
  ThreadMirror? viewing;

  String get selfName => signal.name;
  bool get connected => signal.connected;
  String get link => signal.link;
  List<String> get linkLog => signal.linkLog;
  void logStep(String s) => signal.logStep(s);

  BrainView? get _v => views[selected];

  /// The brains this console can show (linked, online), in name order.
  List<String> get brains => [
    for (final b in signal.brains)
      if (views.containsKey(b)) b,
  ];

  void attachBrain(String name, void Function(Json action) send) {
    views[name] = BrainView(name, send);
    if (selected == null || !views.containsKey(selected) || name == preferred) {
      selected = name;
      viewing = null;
    }
    notifyListeners();
  }

  void detachBrain(String name) {
    views.remove(name);
    if (selected == name) {
      selected = views.keys.firstOrNull;
      viewing = null;
    }
    notifyListeners();
  }

  void handle(String brain, Json m) {
    final v = views[brain];
    if (v == null) return;
    final repaint = v.handle(m);
    if (brain == selected && viewing != null && !v.threads.containsValue(viewing)) {
      viewing = null;
    }
    if (repaint) notifyListeners();
  }

  void select(String brain) {
    if (!views.containsKey(brain)) return;
    selected = brain;
    viewing = null;
    notifyListeners();
  }

  // ---- the selected brain -------------------------------------------------------

  String get brain => selected ?? '';
  bool get selectedIsSelf => selected == selfName;
  bool get ready => connected && _v?.state['ready'] == true;
  String? get startupError => _v?.state['startupError'] as String?;
  String get projectDir => _v?.state['projectDir'] as String? ?? '';
  HubSettings get settings => _v?.settings ?? HubSettings();
  ThreadMirror? get orchestrator => _v?.orchestrator;
  List<ThreadMirror> get workers => _v?.workers ?? const [];
  List<BodyView> get bodies => _v?.bodies ?? const [];
  BodyView? get brainBody => bodies.where((b) => b.isBrain).firstOrNull;

  /// Worker types the orchestrator can run as (the selected brain's body).
  List<String> get workerTypes => brainBody?.workerTypes ?? const [];

  String labelOf(String type) => brainBody?.labelOf(type) ?? type;

  List<Json> modelsFor(String type) => brainBody?.modelsFor(type) ?? const [];


  int get runningCount => workers.where((w) => w.isRunning).length;

  List<ProtocolLogEntry> get protocolLog => local.protocolLog;

  /// Every body in the roster with its owner, for the body list.
  List<BodyEntry> get allBodies {
    BodyView? info(String name) {
      for (final v in [?_v, ...views.values]) {
        final b = v.bodies.where((b) => b.name == name).firstOrNull;
        if (b != null && b.info['workerTypes'] != null) return b;
      }
      return null;
    }

    int running(String name, String? owner) =>
        views[owner]?.workers
            .where((w) => w.body == name && (w.isRunning || w.state == AgentState.queued))
            .length ??
        0;

    return [
      for (final n in signal.nodes)
        if (n.body)
          BodyEntry(n, signal.ownerOf(n.name), info(n.name), running(n.name, signal.ownerOf(n.name))),
    ];
  }

  // ---- actions --------------------------------------------------------------------

  void _act(Json a) => _v?.send(a);

  Future<void> sendToOrchestrator(String text) async {
    viewing = null;
    notifyListeners();
    _act({'a': 'send', 'text': text});
  }

  void interruptOrchestrator() => _act({'a': 'interrupt'});

  Future<void> newConversation({String? workerType}) async {
    viewing = null;
    _act({'a': 'new', 'workerType': workerType});
  }

  void stopWorker(ThreadMirror w) => _act({'a': 'stop', 'id': w.label});

  void answer(PendingRequest r, Object? result) =>
      _act({'a': 'answer', 'requestId': r.request.id, 'result': result});

  /// Sends edited settings (the brain saves them).
  void saveSettings(HubSettings s) =>
      _act({'a': 'settings', 'settings': s.toJson()});

  /// Only a brain's own console can pick its folder: the path is on its
  /// machine.
  void setProject(String dir) => _act({'a': 'project', 'dir': dir});

  /// Whether this console can pause or resume [body]: its owner is a brain
  /// this console is linked to (the owner relays it to the body).
  bool canPause(BodyEntry body) =>
      body.node.online && body.view != null && views.containsKey(body.owner);

  /// Pauses or resumes a body through the brain that owns it.
  void setPaused(BodyEntry body, bool paused) => views[body.owner]?.send({
    'a': 'pause',
    'body': body.name,
    'paused': paused,
  });

  /// Moves a body to a brain (null: no owner) through the signaling server.
  Future<void> assign(String body, String? brain) async {
    notice = 'moving $body to ${brain ?? 'no brain'}…';
    notifyListeners();
    final (ok, reason) = await signal.assign(body, brain);
    notice = ok ? '$body → ${brain ?? 'no brain'}' : 'could not move $body: $reason';
    notifyListeners();
  }

  void view(ThreadMirror? t) {
    viewing = t;
    notifyListeners();
  }

  /// What this console shows, for comparing consoles (`ORCH_DUMP`).
  Json digest() => {
    'self': selfName,
    'isBrain': isBrain,
    'isBody': signal.isBody,
    'roles': roles,
    'connected': connected,
    'link': link,
    'linkLog': linkLog,
    'selected': selected,
    'notice': notice,
    'roster': [
      for (final n in signal.nodes)
        {
          'name': n.name,
          'brain': n.brain,
          'body': n.body,
          'online': n.online,
          'owner': signal.ownerOf(n.name),
          'paused': ?allBodies.where((b) => b.name == n.name).firstOrNull?.view?.paused,
        },
    ],
    'brains': {for (final e in views.entries) e.key: e.value.digest()},
  };
}

/// 32-bit FNV-1a over UTF-16 code units, as hex.
String fnv1a(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return h.toRadixString(16).padLeft(8, '0');
}
