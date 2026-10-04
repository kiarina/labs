import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../claude/bridge_client.dart';
import 'thread_store.dart';
import 'thread_view.dart';

/// A session in the sidebar, from `SDKSessionInfo`.
class ThreadSummary {
  ThreadSummary(Json s)
    : id = s['sessionId'] as String,
      name = s['customTitle'] as String?,
      preview = s['summary'] as String? ?? s['firstPrompt'] as String? ?? '',
      cwd = s['cwd'] as String? ?? '',
      updatedAt = ((s['lastModified'] as num?) ?? 0) ~/ 1000,
      sectionId = s['tag'] as String?;

  final String id;
  String? name;
  String preview;
  final String cwd;
  int updatedAt;
  String status = 'idle';

  /// The session tag; sections are tags.
  String? sectionId;

  String get title {
    if (name != null && name!.isNotEmpty) return name!;
    final firstLine = preview.trim().split('\n').first;
    return firstLine.isEmpty ? 'New session' : firstLine;
  }
}

/// Owns the bridge and everything outside the open session.
class AppController extends ChangeNotifier {
  BridgeClient? client;
  String? startupError;

  /// `{models, account}` from the bridge's `initialize`.
  Json? serverInfo;
  Json? account;

  /// `{id, displayName, supportedEffortLevels}` per model (SDK `ModelInfo`).
  List<Json> models = const [];

  /// Latest `rate_limit_event` info.
  Json? rateLimits;
  final threads = <ThreadSummary>[];
  ThreadView? current;

  /// Section names (session tags), as `{id, name}` for the sidebar.
  List<Json> get sections => [
    for (final s in store.sections) {'id': s, 'name': s},
  ];

  final store = ThreadStore.defaultLocation();

  /// How many of this app's sessions the sidebar reads; "Show more" adds 50.
  int ownLimit = 50;

  /// The project (cwd) a new session starts in.
  String projectDir =
      Platform.environment['CLAUDE_FLUTTER_CWD'] ??
      Platform.environment['HOME'] ??
      '/';
  String? model;
  String? effort;

  /// Claude Code permission mode: default | acceptEdits | plan | auto |
  /// bypassPermissions.
  String accessMode = Platform.environment['CLAUDE_FLUTTER_MODE'] ?? 'default';

  /// Claude in Chrome (`claude --chrome`). Applies when Claude Code starts,
  /// so toggling it restarts the open session's process (if idle).
  bool chrome = Platform.environment['CLAUDE_FLUTTER_CHROME'] == '1';

  void setChrome(bool value) {
    chrome = value;
    notifyListeners();
    final view = current;
    if (view != null && !view.isRunning) {
      client?.request('session/close', {'sessionId': view.threadId});
    }
  }

  final protocolLog = <ProtocolLogEntry>[];
  final _subscriptions = <StreamSubscription<dynamic>>[];

  Future<void> start() async {
    try {
      final (exe, args, dir) = resolveBridgeCommand();
      final c = BridgeClient(executable: exe, arguments: args);
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
      await c.start(workingDirectory: dir);
      unawaited(
        c.exitCode.then((code) {
          startupError =
              'bridge exited ($code)\n${c.stderrLines.take(20).join('\n')}';
          notifyListeners();
        }),
      );
      await store.open();
      final r = await c.request('initialize', {'cwd': projectDir}) as Map;
      serverInfo = r.cast<String, dynamic>();
      account = (r['account'] as Map?)?.cast<String, dynamic>();
      models = (r['models'] as List).cast<Map>().map((m) {
        return <String, dynamic>{
          'id': m['value'],
          'displayName': m['displayName'],
          'supportedEffortLevels': m['supportedEffortLevels'] ?? const [],
        };
      }).toList();
      model ??= models.firstOrNull?['id'] as String?;
      effort ??= effortOptions.contains('medium') ? 'medium' : null;
      notifyListeners();
      await refreshThreads();
    } catch (e) {
      startupError = '$e';
      notifyListeners();
    }
  }

  bool onlyOwnThreads = true;

  bool get hasMoreOwnThreads => onlyOwnThreads && store.length > ownLimit;

  void setOnlyOwnThreads(bool value) {
    onlyOwnThreads = value;
    notifyListeners();
    refreshThreads();
  }

  void showMoreThreads() {
    ownLimit += 50;
    refreshThreads();
  }

  Future<void> refreshThreads() async {
    final List<Json> infos;
    if (onlyOwnThreads) {
      // Read only the remembered sessions: cost follows what is shown.
      final ids = store.recent(limit: ownLimit);
      final r =
          await client!.request('session/infos', {'sessionIds': ids}) as Map;
      final list = (r['infos'] as List);
      infos = [];
      for (var i = 0; i < ids.length; i++) {
        final info = list[i] as Map?;
        if (info == null) {
          // Deleted elsewhere: forget it.
          await store.remove(ids[i]);
        } else {
          infos.add(info.cast<String, dynamic>());
        }
      }
    } else {
      final r = await client!.request('session/list', {'limit': 50}) as Map;
      infos = (r['sessions'] as List)
          .cast<Map>()
          .map((s) => s.cast<String, dynamic>())
          .toList();
    }
    final found = infos.map(ThreadSummary.new).toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    // A tag that is not a known section yet (set by another client) shows up.
    final tags = found.map((t) => t.sectionId).nonNulls.toSet();
    final missing = tags.where((t) => !store.sections.contains(t)).toList();
    if (missing.isNotEmpty) {
      await store.setSections([...store.sections, ...missing]);
    }
    for (final t in found) {
      if (current?.threadId == t.id && current!.isRunning) t.status = 'active';
    }
    threads
      ..clear()
      ..addAll(found);
    notifyListeners();
  }

  // ---- sections (session tags) ---------------------------------------------

  Future<String> createSection(String name) async {
    if (!store.sections.contains(name)) {
      await store.setSections([...store.sections, name]);
    }
    notifyListeners();
    return name;
  }

  Future<void> renameSection(String old, String name) async {
    for (final t in threads.where((t) => t.sectionId == old)) {
      await client!.request('session/tag', {'sessionId': t.id, 'tag': name});
      t.sectionId = name;
    }
    await store.setSections([
      for (final s in store.sections) s == old ? name : s,
    ]);
    notifyListeners();
  }

  Future<void> deleteSection(String name) async {
    for (final t in threads.where((t) => t.sectionId == name)) {
      await client!.request('session/tag', {'sessionId': t.id, 'tag': null});
      t.sectionId = null;
    }
    await store.setSections(store.sections.where((s) => s != name).toList());
    notifyListeners();
  }

  Future<void> moveToSection(ThreadSummary t, String? section) async {
    await client!.request('session/tag', {'sessionId': t.id, 'tag': section});
    t.sectionId = section;
    notifyListeners();
  }

  // ---- model / effort / mode -----------------------------------------------

  Json? get currentModel => models.where((m) => m['id'] == model).firstOrNull;

  List<String> get effortOptions =>
      ((currentModel?['supportedEffortLevels'] as List?) ?? const [])
          .cast<String>();

  void setModel(String id) {
    model = id;
    if (effort != null && !effortOptions.contains(effort)) {
      effort = effortOptions.contains('medium') ? 'medium' : null;
    }
    notifyListeners();
    final view = current;
    if (view != null) {
      client!.request('session/setModel', {
        'sessionId': view.threadId,
        'model': id,
      });
    }
  }

  void setEffort(String value) {
    effort = value;
    notifyListeners();
    final view = current;
    if (view != null) {
      client!.request('session/setEffort', {
        'sessionId': view.threadId,
        'effort': value,
      });
    }
  }

  void setAccessMode(String mode) {
    accessMode = mode;
    notifyListeners();
    final view = current;
    if (view != null) {
      client!.request('session/setPermissionMode', {
        'sessionId': view.threadId,
        'mode': mode,
      });
    }
  }

  void setProjectDir(String dir) {
    projectDir = dir;
    notifyListeners();
  }

  Json get _sessionConfig => {
    'cwd': current?.cwd ?? projectDir,
    'model': ?model,
    'effort': ?effort,
    'permissionMode': accessMode,
    'chrome': chrome,
  };

  // ---- sessions -------------------------------------------------------------

  /// Clears the transcript; the session starts on the first message.
  void newThread() {
    _leave();
    current = null;
    notifyListeners();
  }

  /// Closes the Claude Code process of the session being left, unless it is
  /// still working (it then keeps running and is closed when it finishes).
  void _leave() {
    final view = current;
    if (view == null) return;
    if (!view.isRunning) {
      client?.request('session/close', {'sessionId': view.threadId});
    }
    view.dispose();
  }

  Future<void> openThread(ThreadSummary summary) async {
    _leave();
    final view = ThreadView(
      threadId: summary.id,
      cwd: summary.cwd,
      title: summary.title,
    );
    current = view;
    notifyListeners();
    if (store.contains(summary.id)) unawaited(store.touch(summary.id));
    final r = await client!.request('session/messages', {
      'sessionId': summary.id,
    }) as Map;
    view.loadHistory(r['messages'] as List);
    notifyListeners();
  }

  Future<void> send(String text) async {
    var view = current;
    if (view == null) {
      final config = {..._sessionConfig, 'cwd': projectDir};
      final r = await client!.request('session/start', {
        ...config,
        'text': text,
      }) as Map;
      final id = r['sessionId'] as String;
      view = ThreadView(threadId: id, cwd: projectDir)..model = model;
      current = view;
      view.addUserTurn(text);
      await store.touch(id);
      threads.insert(
        0,
        ThreadSummary({
          'sessionId': id,
          'summary': text,
          'cwd': projectDir,
          'lastModified': DateTime.now().millisecondsSinceEpoch,
        })..status = 'active',
      );
      notifyListeners();
      return;
    }
    // While a turn runs this is a steer: the bridge sends it with
    // priority "now"; the SDK ends the running turn and runs it next.
    view.addUserTurn(text);
    if (store.contains(view.threadId)) unawaited(store.touch(view.threadId));
    _setStatus(view.threadId, 'active');
    await client!.request('session/send', {
      ..._sessionConfig,
      'sessionId': view.threadId,
      'text': text,
    });
  }

  Future<void> interrupt() async {
    final view = current;
    if (view == null || !view.isRunning) return;
    await client!.request('session/interrupt', {'sessionId': view.threadId});
  }

  /// Claude Code has no archive; this deletes the session file.
  Future<void> archive(ThreadSummary t) async {
    await client!.request('session/delete', {'sessionId': t.id});
    await store.remove(t.id);
    threads.remove(t);
    if (current?.threadId == t.id) newThread();
    notifyListeners();
  }

  void answer(PendingRequest r, Object? result) {
    client!.respond(r.request.id, result);
    current?.removePending(r);
  }

  void _setStatus(String sessionId, String status) {
    for (final t in threads.where((t) => t.id == sessionId)) {
      t.status = status;
      t.updatedAt = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    }
    notifyListeners();
  }

  void _onNotification(ServerNotification n) {
    final sessionId = n.params['sessionId'] as String?;
    switch (n.method) {
      case 'sdk/message':
        final m = (n.params['message'] as Map).cast<String, dynamic>();
        if (m['type'] == 'rate_limit_event') {
          rateLimits = (m['rate_limit_info'] as Map).cast<String, dynamic>();
          notifyListeners();
          return;
        }
        if (sessionId != null && sessionId == current?.threadId) {
          current!.handleSdkMessage(m);
          final mode = current!.permissionMode;
          if (mode != null && mode != accessMode) {
            accessMode = mode;
            notifyListeners();
          }
          if (m['type'] == 'result') unawaited(_afterResult(current!));
        }
        if (m['type'] == 'result') {
          final view = current;
          final running =
              view != null && view.threadId == sessionId && view.isRunning;
          if (!running) _setStatus(sessionId!, 'idle');
          // A session left while running: close it now that it finished.
          if (view?.threadId != sessionId) {
            client!.request('session/close', {'sessionId': sessionId});
          }
        }
      case 'permission/cancelled':
        current?.cancelPending(n.params['requestId'] as String);
      case 'session/error':
        current?.errors.add(n.params['message'] as String);
        _setStatus(sessionId!, 'idle');
    }
  }

  /// Context window use and the auto-generated title, after each turn.
  Future<void> _afterResult(ThreadView view) async {
    final usage = await client!.request('session/contextUsage', {
      'sessionId': view.threadId,
    });
    if (usage is Map) {
      view.tokenUsage = {
        'modelContextWindow': usage['maxTokens'],
        'last': {'inputTokens': usage['totalTokens']},
      };
    }
    final r = await client!.request('session/infos', {
      'sessionIds': [view.threadId],
    }) as Map;
    final info = (r['infos'] as List).first as Map?;
    if (info != null) {
      final s = ThreadSummary(info.cast<String, dynamic>());
      view.title = s.title;
      for (final t in threads.where((t) => t.id == s.id)) {
        t
          ..name = s.name
          ..preview = s.preview;
      }
    }
    view.refresh();
    notifyListeners();
  }

  void _onRequest(ServerRequest r) {
    final view = current;
    if (view != null && r.params['sessionId'] == view.threadId) {
      view.addPending(r);
      return;
    }
    // A prompt for a session that is not on screen: deny so it does not hang.
    client!.respond(r.id, {
      'behavior': 'deny',
      'message': 'The session is not open in the app',
    });
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
