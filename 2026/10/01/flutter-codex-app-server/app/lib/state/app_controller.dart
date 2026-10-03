import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../codex/app_server_client.dart';
import 'thread_view.dart';

class ThreadSummary {
  ThreadSummary(Json t)
    : id = t['id'] as String,
      preview = t['preview'] as String? ?? '',
      name = t['name'] as String?,
      cwd = t['cwd'] as String? ?? '',
      updatedAt = (t['updatedAt'] as num?)?.toInt() ?? 0,
      status = (t['status'] as Map?)?['type'] as String? ?? 'notLoaded';

  final String id;
  String preview;
  String? name;
  final String cwd;
  int updatedAt;
  String status;

  String get title {
    if (name != null && name!.isNotEmpty) return name!;
    final firstLine = preview.trim().split('\n').first;
    return firstLine.isEmpty ? 'New thread' : firstLine;
  }
}

/// Owns the app-server connection and everything outside the open thread.
class AppController extends ChangeNotifier {
  AppServerClient? client;
  String? startupError;
  Json? serverInfo;
  Json? account;
  List<Json> models = const [];
  Json? rateLimits;
  final threads = <ThreadSummary>[];
  ThreadView? current;

  /// The project (cwd) a new thread starts in.
  String projectDir =
      Platform.environment['CODEX_FLUTTER_CWD'] ??
      Platform.environment['HOME'] ??
      '/';
  String? model;
  String? effort;

  /// 'read-only' | 'agent' | 'full', the three modes of the Codex app.
  String accessMode = Platform.environment['CODEX_FLUTTER_ACCESS'] ?? 'agent';

  String get approvalPolicy => accessMode == 'full' ? 'never' : 'on-request';

  String get sandbox => switch (accessMode) {
    'read-only' => 'read-only',
    'full' => 'danger-full-access',
    _ => 'workspace-write',
  };

  Json get sandboxPolicy => switch (accessMode) {
    'read-only' => {'type': 'readOnly', 'networkAccess': false},
    'full' => {'type': 'dangerFullAccess'},
    _ => {
      'type': 'workspaceWrite',
      'writableRoots': <String>[],
      'networkAccess': false,
      'excludeTmpdirEnvVar': false,
      'excludeSlashTmp': false,
    },
  };

  void setAccessMode(String mode) {
    accessMode = mode;
    notifyListeners();
  }

  final protocolLog = <ProtocolLogEntry>[];
  final _subscriptions = <StreamSubscription<dynamic>>[];

  Future<void> start() async {
    try {
      final (exe, args) = await resolveCodexCommand();
      final c = AppServerClient(executable: exe, arguments: args);
      client = c;
      _subscriptions
        ..add(
          c.log.listen((e) {
            protocolLog.add(e);
            if (protocolLog.length > 2000) protocolLog.removeRange(0, 500);
          }),
        )
        ..add(c.notifications.listen(_onNotification))
        ..add(c.requests.listen(_onRequest));
      await c.start(workingDirectory: projectDir);
      unawaited(
        c.exitCode.then((code) {
          startupError =
              'codex app-server exited ($code)\n'
              '${c.stderrLines.take(20).join('\n')}';
          notifyListeners();
        }),
      );
      serverInfo = await c.initialize(
        name: clientName,
        title: 'Codex Flutter (lab)',
        version: '0.1.0',
      );
      notifyListeners();
      await Future.wait([
        _loadAccount(),
        _loadModels(),
        refreshThreads(),
        _loadRateLimits(),
      ]);
    } catch (e) {
      startupError = '$e';
      notifyListeners();
    }
  }

  Future<void> _loadAccount() async {
    final r = await client!.request('account/read', {}) as Map;
    account = (r['account'] as Map?)?.cast<String, dynamic>();
    notifyListeners();
  }

  Future<void> _loadModels() async {
    final r = await client!.request('model/list', {}) as Map;
    models = (r['data'] as List)
        .cast<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList();
    final def =
        models.where((m) => m['isDefault'] == true).firstOrNull ??
        models.firstOrNull;
    model ??= def?['id'] as String?;
    effort ??= def?['defaultReasoningEffort'] as String?;
    notifyListeners();
  }

  Future<void> _loadRateLimits() async {
    try {
      final r = await client!.request('account/rateLimits/read') as Map;
      rateLimits = (r['rateLimits'] as Map?)?.cast<String, dynamic>();
      notifyListeners();
    } on AppServerError {
      // Not available for API-key auth.
    }
  }

  /// Sent as `clientInfo.name`; app-server records it as each thread's
  /// `originator`, which is how this app recognizes its own threads.
  static const clientName = 'codex_flutter';

  /// Show only threads started by this app (the default) or every local
  /// thread (CLI, IDE, Codex app, `codex exec`, ...).
  bool onlyOwnThreads = true;

  void setOnlyOwnThreads(bool value) {
    onlyOwnThreads = value;
    notifyListeners();
    refreshThreads();
  }

  Future<void> refreshThreads() async {
    const wanted = 50;
    final found = <ThreadSummary>[];
    String? cursor;
    // The local app-server rejects the `originators` filter, so page through
    // the list and keep this app's threads. Other clients (`codex exec` in
    // particular) can start many threads, hence several pages.
    for (var page = 0; page < 20 && found.length < wanted; page++) {
      final r = await client!.request('thread/list', {
        'limit': onlyOwnThreads ? 100 : wanted,
        'sortKey': 'updated_at',
        'cursor': ?cursor,
        // Include threads started by the CLI, the IDE extension and app-server
        // clients (this app), like the Codex app does.
        'sourceKinds': ['cli', 'vscode', 'appServer', 'exec'],
      }) as Map;
      for (final t in (r['data'] as List).cast<Map>()) {
        if (onlyOwnThreads && t['originator'] != clientName) continue;
        found.add(ThreadSummary(t.cast<String, dynamic>()));
      }
      // Show what has been found so far; scanning many pages takes seconds.
      threads
        ..clear()
        ..addAll(found.take(wanted));
      notifyListeners();
      cursor = r['nextCursor'] as String?;
      if (cursor == null || !onlyOwnThreads) break;
    }
  }

  Json? get currentModel => models.where((m) => m['id'] == model).firstOrNull;

  List<String> get effortOptions =>
      ((currentModel?['supportedReasoningEfforts'] as List?) ?? const [])
          .cast<Map>()
          .map((e) => e['reasoningEffort'] as String)
          .toList();

  void setModel(String id) {
    model = id;
    final options = effortOptions;
    if (effort == null || !options.contains(effort)) {
      effort = currentModel?['defaultReasoningEffort'] as String?;
    }
    notifyListeners();
  }

  void setEffort(String value) {
    effort = value;
    notifyListeners();
  }

  void setProjectDir(String dir) {
    projectDir = dir;
    notifyListeners();
  }

  /// Clears the transcript; the thread itself is created on the first message
  /// (like the Codex app).
  void newThread() {
    current?.dispose();
    current = null;
    notifyListeners();
  }

  Future<void> openThread(ThreadSummary summary) async {
    current?.dispose();
    final view = ThreadView(
      threadId: summary.id,
      cwd: summary.cwd,
      title: summary.title,
    );
    current = view;
    notifyListeners();
    final r = await client!.request('thread/resume', {
      'threadId': summary.id,
      'approvalPolicy': approvalPolicy,
      'sandbox': sandbox,
    }) as Map;
    final thread = (r['thread'] as Map).cast<String, dynamic>();
    view
      ..model = r['model'] as String?
      ..effort = r['reasoningEffort'] as String?
      ..cwd = r['cwd'] as String? ?? view.cwd
      ..status = (thread['status'] as Map?)?['type'] as String? ?? 'idle';
    if (view.model != null && models.any((m) => m['id'] == view.model)) {
      model = view.model;
      effort = view.effort ?? effort;
    }
    view.loadTurns(thread['turns'] as List? ?? const []);
    notifyListeners();
  }

  Future<void> send(String text) async {
    final input = [
      {'type': 'text', 'text': text, 'text_elements': <Object>[]},
    ];
    var view = current;
    if (view == null) {
      final r = await client!.request('thread/start', {
        'cwd': projectDir,
        'model': ?model,
        'approvalPolicy': approvalPolicy,
        'sandbox': sandbox,
      }) as Map;
      final thread = (r['thread'] as Map).cast<String, dynamic>();
      view = ThreadView(
        threadId: thread['id'] as String,
        cwd: r['cwd'] as String,
      )..model = r['model'] as String?;
      current = view;
      // thread/started usually arrives before the response.
      final summary = threads.where((t) => t.id == view!.threadId).firstOrNull;
      if (summary == null) {
        threads.insert(0, ThreadSummary(thread)..preview = text);
      } else {
        summary.preview = text;
      }
      notifyListeners();
    }
    final active = view.activeTurn;
    if (active != null) {
      // Same as typing while Codex is working: steer the running turn.
      await client!.request('turn/steer', {
        'threadId': view.threadId,
        'expectedTurnId': active.id,
        'input': input,
      });
      return;
    }
    final r = await client!.request('turn/start', {
      'threadId': view.threadId,
      'input': input,
      'model': ?model,
      'effort': ?effort,
      'approvalPolicy': approvalPolicy,
      'sandboxPolicy': sandboxPolicy,
    }) as Map;
    final turn = (r['turn'] as Map).cast<String, dynamic>();
    // turn/started may arrive later; make the spinner appear right away.
    view.handleNotification(
      ServerNotification('turn/started', {
        'threadId': view.threadId,
        'turn': turn,
      }),
    );
  }

  Future<void> interrupt() async {
    final view = current;
    final turn = view?.activeTurn;
    if (view == null || turn == null) return;
    await client!.request('turn/interrupt', {
      'threadId': view.threadId,
      'turnId': turn.id,
    });
  }

  Future<void> archive(ThreadSummary t) async {
    await client!.request('thread/archive', {'threadId': t.id});
    threads.remove(t);
    if (current?.threadId == t.id) newThread();
    notifyListeners();
  }

  void answer(PendingRequest r, Object? result) {
    client!.respond(r.request.id, result);
    current?.removePending(r);
  }

  void _onNotification(ServerNotification n) {
    final threadId =
        n.params['threadId'] as String? ??
        ((n.params['thread'] as Map?)?['id'] as String?);
    switch (n.method) {
      case 'thread/started':
        final t = ThreadSummary(
          (n.params['thread'] as Map).cast<String, dynamic>(),
        );
        if (!threads.any((e) => e.id == t.id)) threads.insert(0, t);
        notifyListeners();
      case 'thread/name/updated':
        for (final t in threads.where((t) => t.id == threadId)) {
          t.name = n.params['threadName'] as String?;
        }
        notifyListeners();
      case 'thread/status/changed':
        for (final t in threads.where((t) => t.id == threadId)) {
          t.status = (n.params['status'] as Map)['type'] as String;
          t.updatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        }
        notifyListeners();
      case 'account/rateLimits/updated':
        final update = (n.params['rateLimits'] as Map).cast<String, dynamic>();
        rateLimits = {
          ...?rateLimits,
          for (final e in update.entries)
            if (e.value != null) e.key: e.value,
        };
        notifyListeners();
    }
    if (threadId != null && threadId == current?.threadId) {
      current!.handleNotification(n);
    }
  }

  void _onRequest(ServerRequest r) {
    final view = current;
    if (view != null && r.params['threadId'] == view.threadId) {
      view.addPending(r);
      return;
    }
    // A request for a thread that is not on screen: decline so the agent does
    // not hang. The Codex app would badge the thread instead.
    client!.respondError(r.id, -32000, 'thread not open in this client');
  }

  @override
  void dispose() {
    for (final s in _subscriptions) {
      s.cancel();
    }
    client?.dispose();
    super.dispose();
  }
}
