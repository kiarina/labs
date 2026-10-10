import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_orchestrator/agents/agent_check.dart';
import 'package:agent_orchestrator/agents/mac_permissions.dart';
import 'package:agent_orchestrator/agents/worker_types.dart';
import 'package:agent_orchestrator/mesh/launch.dart';
import 'package:agent_orchestrator/ui/launch_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orchestrator_signal/signal_server.dart';

/// Answers checks without starting agents: Codex needs a login until
/// [codexLogin] runs; Claude is fine; custom ones need a model.
class FakeChecker extends AgentChecker {
  bool codexLoggedIn = false;
  final calls = <String>[];

  @override
  Future<CheckResult> codex(String? cwd) async {
    calls.add('codex $cwd');
    return codexLoggedIn
        ? const CheckResult(true, 'Logged in (plus)')
        : const CheckResult(false, 'Not logged in', needsLogin: true);
  }

  @override
  Future<CheckResult> codexLogin() async {
    calls.add('login');
    codexLoggedIn = true;
    return const CheckResult(true, 'Logged in');
  }

  @override
  Future<CheckResult> claude(String? cwd) async {
    calls.add('claude $cwd');
    return const CheckResult(true, 'Logged in (max)');
  }

  @override
  Future<CheckResult> custom(WorkerType t) async {
    calls.add('custom ${t.id}');
    return CheckResult(true, 'Reachable, has ${t.model}');
  }

  @override
  Future<List<Requirement>> computerUse() async {
    calls.add('computerUse');
    return const [Requirement('Codex Computer Use', true, 'Installed'), Requirement('Computer Use plugin', false, 'Off')];
  }

  @override
  Future<List<Requirement>> chrome() async {
    calls.add('chrome');
    return const [Requirement('Google Chrome', true, 'Installed')];
  }

  @override
  Future<List<Requirement>> peekaboo() async {
    calls.add('peekaboo');
    return const [Requirement('Peekaboo: Accessibility', false, 'Not granted', settingsPane: 'Privacy_Accessibility')];
  }

  @override
  Future<(List<ModelInfo>?, String?)> models(String baseUrl, String? envKey) async {
    calls.add('models $baseUrl');
    if (!baseUrl.startsWith('http')) return (null, 'Enter a URL like http://127.0.0.1:8500/v1');
    return (const [ModelInfo('qwen-a', 262144), ModelInfo('qwen-b', null)], null);
  }
}

/// macOS permissions without macOS: Screen Recording is granted only after
/// a "restart".
class FakePermissions extends MacPermissions {
  FakePermissions();

  bool accessibility = false;
  bool screenAsked = false;
  final opened = <String>[];

  @override
  Future<Map<String, bool>?> status() async => {'accessibility': accessibility, 'screenRecording': false};

  @override
  Future<void> requestAccessibility() async => accessibility = true;

  @override
  Future<void> requestScreenRecording() async => screenAsked = true;

  @override
  Future<void> openSettings(String pane) async => opened.add(pane);
}

/// Every check passes (for tests about other steps).
class _NoChecks extends AgentChecker {
  const _NoChecks();

  @override
  Future<CheckResult> codex(String? cwd) async => const CheckResult(true, 'ok');

  @override
  Future<CheckResult> claude(String? cwd) async => const CheckResult(true, 'ok');

  @override
  Future<CheckResult> custom(WorkerType t) async => const CheckResult(true, 'ok');

  @override
  Future<List<Requirement>> computerUse() async => const [];

  @override
  Future<List<Requirement>> chrome() async => const [];

  @override
  Future<List<Requirement>> peekaboo() async => const [];
}

/// Joins [server] as an app (a brain or a body), as the real apps do.
Future<WebSocket> join(int port, String name, {bool brain = false}) async {
  final ws = await WebSocket.connect('ws://127.0.0.1:$port');
  ws.add(jsonEncode({'t': 'hello', 'name': name, 'brain': brain, 'body': true}));
  ws.listen((_) {});
  return ws;
}

void main() {
  // The test binding answers every HttpClient request with 400; the page
  // reads a real signaling server.
  setUpAll(() => HttpOverrides.global = null);
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('launch'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<Completer<(LaunchConfig, SignalServer?)>> pumpPage(
    WidgetTester tester,
    LaunchConfig initial, {
    AgentChecker checker = const _NoChecks(),
    MacPermissions? permissions,
  }) async {
    final started = Completer<(LaunchConfig, SignalServer?)>();
    tester.view.physicalSize = const Size(1200, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: LaunchPage(
        initial: initial,
        ownersFile: File('${tmp.path}/owners.json'),
        typesFile: File('${tmp.path}/worker-types.json'),
        stateDir: tmp.path,
        checker: checker,
        permissions: permissions ?? FakePermissions(),
        onStart: (c, s) => started.complete((c, s)),
      ),
    ));
    return started;
  }

  /// Taps a button whose handler does real I/O, and waits for it: each
  /// real wait lets the I/O finish, each pump runs what follows it in the
  /// test zone.
  Future<void> tapAndWait(WidgetTester tester, Finder f) async {
    await tester.tap(f);
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
  }

  testWidgets('join, body, pick a brain from the roster', (tester) async {
    late SignalServer server;
    late int port;
    late List<WebSocket> apps;
    await tester.runAsync(() async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = probe.port;
      await probe.close();
      server = SignalServer(port: port, log: (_) {});
      await server.start();
      apps = [
        await join(port, 'brain-a', brain: true),
        await join(port, 'brain-b', brain: true),
        await join(port, 'body-c'),
      ];
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    final started = await pumpPage(tester, LaunchConfig(url: 'ws://127.0.0.1:$port'));

    expect(find.text('1. Signaling   2. Roles   3. Belongs to   4. Agents', findRichText: true), findsOneWidget);
    await tester.tap(find.byKey(const Key('signal-join')));
    await tester.pump();
    await tapAndWait(tester, find.byKey(const Key('next')));

    // Step 2: the roster was read; a taken name is flagged.
    expect(find.textContaining('2 brain(s) there'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('name')), 'body-c');
    await tester.pump();
    expect(find.textContaining('this one will get a suffix'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('name')), 'body-d');
    await tester.pump();
    expect(find.text('Next'), findsOneWidget);
    await tester.tap(find.byKey(const Key('next')));
    await tester.pumpAndSettle();

    // Step 3: brains from the roster.
    await tester.tap(find.byKey(const Key('owner')));
    await tester.pumpAndSettle();
    expect(find.text('brain-a').hitTestable(), findsOneWidget);
    expect(find.text('brain-b').hitTestable(), findsOneWidget);
    await tester.tap(find.text('brain-b').hitTestable());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('next')));
    await tester.pumpAndSettle();
    // Step 4: agents; Codex and Claude are on by default.
    expect(find.text('1. Signaling   2. Roles   3. Belongs to   4. Agents', findRichText: true), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    await tester.tap(find.byKey(const Key('next')));
    final (c, s) = await started.future;
    expect((c.name, c.brain, c.body, c.signaling, c.owner, c.assignOwner, s),
        ('body-d', false, true, false, 'brain-b', true, null));

    await tester.runAsync(() async {
      for (final a in apps) {
        await a.close();
      }
      await server.close();
    });
  });

  testWidgets('start signaling: a used port stops at step 1; brain + body', (tester) async {
    late ServerSocket busy;
    late int free;
    await tester.runAsync(() async {
      busy = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      free = probe.port;
      await probe.close();
    });
    final started = await pumpPage(tester, LaunchConfig(port: busy.port));
    await tester.tap(find.byKey(const Key('signal-start')));
    await tester.pump();
    await tapAndWait(tester, find.byKey(const Key('next')));
    expect(find.textContaining('it is in use'), findsOneWidget);
    expect(find.byKey(const Key('port')), findsOneWidget); // still step 1

    await tester.enterText(find.byKey(const Key('port')), '$free');
    await tapAndWait(tester, find.byKey(const Key('next')));
    expect(find.textContaining('0 brain(s) there'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('name')), 'brain-a');
    await tester.tap(find.byKey(const Key('role-brain')));
    await tester.pump();
    await tester.tap(find.byKey(const Key('next')));
    await tester.pumpAndSettle();
    // A brain that is a body belongs to itself by default.
    expect(find.text('brain-a (this app)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('next')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('next')));
    final (c, s) = await started.future;
    expect((c.brain, c.body, c.signaling, c.port, c.owner, c.signalUrl),
        (true, true, true, free, LaunchConfig.self, 'ws://127.0.0.1:$free'));
    expect(s, isNotNull);
    await tester.runAsync(() async {
      await s!.close();
      await busy.close();
    });
  });

  testWidgets('neither brain nor body starts a console from step 2', (tester) async {
    late SignalServer server;
    late int port;
    await tester.runAsync(() async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = probe.port;
      await probe.close();
      server = SignalServer(port: port, log: (_) {});
      await server.start();
    });
    final started = await pumpPage(tester, LaunchConfig(url: 'ws://127.0.0.1:$port'));
    await tapAndWait(tester, find.byKey(const Key('next')));
    await tester.tap(find.byKey(const Key('role-body')));
    await tester.pump();
    expect(find.text('1. Signaling   2. Roles', findRichText: true), findsOneWidget);
    expect(find.textContaining('console only'), findsOneWidget);
    expect(find.text('Start'), findsOneWidget);
    await tester.tap(find.byKey(const Key('next')));
    final (c, _) = await started.future;
    expect((c.brain, c.body, c.assignOwner), (false, false, false));
    await tester.runAsync(server.close);
  });

  testWidgets('agents: log in to Codex, turn Claude off, add a custom one; saved', (tester) async {
    late SignalServer server;
    late int port;
    await tester.runAsync(() async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = probe.port;
      await probe.close();
      server = SignalServer(port: port, log: (_) {});
      await server.start();
    });
    final checker = FakeChecker();
    final started = await pumpPage(
      tester,
      LaunchConfig(url: 'ws://127.0.0.1:$port', brain: true, body: true),
      checker: checker,
    );
    await tapAndWait(tester, find.byKey(const Key('next'))); // signaling
    await tester.enterText(find.byKey(const Key('name')), 'brain-z');
    await tester.tap(find.byKey(const Key('next'))); // roles
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('next'))); // belongs to
    await tester.pumpAndSettle();

    // Entering the step checks what is on.
    expect(checker.calls, ['codex null', 'claude null']);
    expect(find.textContaining('Not logged in'), findsOneWidget);
    await tester.tap(find.byKey(const Key('codex-login')));
    await tester.pumpAndSettle();
    expect(checker.calls.sublist(2), ['login', 'codex null']);
    expect(find.text('✓ Logged in (plus)'), findsOneWidget);

    await tester.tap(find.byKey(const Key('agent-claude')));
    await tester.pumpAndSettle();

    // A custom one with a bad id is refused on Start.
    await tester.tap(find.byKey(const Key('add-custom')));
    await tester.pumpAndSettle();
    final card = find.byKey(const Key('custom-c0'));
    expect(card, findsOneWidget, reason: 'the first draft in this test run');
    Future<void> type(String field, String text) async {
      await tester.enterText(find.byKey(Key('custom-c0-$field')), text);
      await tester.pump();
    }
    await type('id', 'Bad Id');
    // Before the list is loaded, the model is typed; a bad URL says so.
    expect(find.byKey(const Key('custom-c0-model')), findsOneWidget);
    await type('url', 'nope');
    await tester.tap(find.byKey(const Key('load-c0')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Enter a URL like'), findsOneWidget);
    await type('url', 'http://127.0.0.1:9/v1');
    await tester.tap(find.byKey(const Key('load-c0')));
    await tester.pumpAndSettle();
    // Loaded: a list with context windows; the first is picked.
    expect(find.byKey(const Key('custom-c0-model-list')), findsOneWidget);
    expect(find.text('qwen-a  ·  262K context'), findsOneWidget);
    await tester.tap(find.byKey(const Key('custom-c0-model-list')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('qwen-b').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('next')));
    await tester.tap(find.byKey(const Key('next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('use a-z'), findsOneWidget);
    await type('id', 'local-qwen');
    expect(find.text('No limit'), findsOneWidget);
    final slider = tester.getRect(find.byKey(const Key('custom-c0-max')));
    await tester.tapAt(Offset(slider.left + slider.width * 0.3, slider.center.dy));
    await tester.pumpAndSettle();
    final max = int.parse(tester.widget<Text>(find.byKey(const Key('custom-c0-max-text'))).data!);
    expect(max, inInclusiveRange(1, 8));
    await tester.ensureVisible(find.byKey(const Key('check-c0')));
    await tester.tap(find.byKey(const Key('check-c0')));
    await tester.pumpAndSettle();
    expect(find.text('✓ Reachable, has qwen-b'), findsOneWidget);

    await tester.ensureVisible(find.byKey(const Key('next')));
    await tester.tap(find.byKey(const Key('next')));
    final (c, _) = await started.future;
    expect(c.orchestrator, 'codex');
    final saved = jsonDecode(File('${tmp.path}/worker-types.json').readAsStringSync());
    expect(saved, {
      'codex': {'enabled': true},
      'claude': {'enabled': false},
      'custom': [
        {
          'id': 'local-qwen',
          'base_url': 'http://127.0.0.1:9/v1',
          'model': 'qwen-b',
          'description': '',
          'max_concurrent': max,
        },
      ],
    });
    await tester.runAsync(server.close);
  });

  testWidgets('a brain with no agents cannot start; a body can', (tester) async {
    late SignalServer server;
    late int port;
    await tester.runAsync(() async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = probe.port;
      await probe.close();
      server = SignalServer(port: port, log: (_) {});
      await server.start();
    });
    final started = await pumpPage(
      tester,
      LaunchConfig(url: 'ws://127.0.0.1:$port', brain: true, body: false),
    );
    await tapAndWait(tester, find.byKey(const Key('next')));
    await tester.tap(find.byKey(const Key('next'))); // roles -> agents
    await tester.pumpAndSettle();
    expect(find.text('1. Signaling   2. Roles   3. Agents', findRichText: true), findsOneWidget);
    await tester.tap(find.byKey(const Key('agent-codex')));
    await tester.tap(find.byKey(const Key('agent-claude')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('next')));
    await tester.pumpAndSettle();
    expect(find.textContaining('A brain needs at least one agent'), findsOneWidget);

    // As a body only, none is fine.
    await tester.tap(find.byKey(const Key('back')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('role-brain')));
    await tester.tap(find.byKey(const Key('role-body')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('next'))); // roles -> belongs to
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('next'))); // -> agents
    await tester.pumpAndSettle();
    expect(find.textContaining('only its tools'), findsOneWidget);
    await tester.tap(find.byKey(const Key('next')));
    final (c, _) = await started.future;
    expect((c.brain, c.body), (false, true));
    final saved = jsonDecode(File('${tmp.path}/worker-types.json').readAsStringSync()) as Map;
    expect((saved['codex'] as Map)['enabled'], false);
    expect((saved['claude'] as Map)['enabled'], false);
    await tester.runAsync(server.close);
  });

  testWidgets('tools: switches show what they need; permissions are granted here; saved', (tester) async {
    late SignalServer server;
    late int port;
    await tester.runAsync(() async {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      port = probe.port;
      await probe.close();
      server = SignalServer(port: port, log: (_) {});
      await server.start();
    });
    final checker = FakeChecker()..codexLoggedIn = true;
    final perms = FakePermissions();
    final started = await pumpPage(
      tester,
      LaunchConfig(url: 'ws://127.0.0.1:$port', body: true),
      checker: checker,
      permissions: perms,
    );
    await tapAndWait(tester, find.byKey(const Key('next')));
    await tester.tap(find.byKey(const Key('next'))); // roles
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('next'))); // belongs to
    await tester.pumpAndSettle();

    // This app's permissions: Accessibility is granted here.
    expect(find.textContaining('Accessibility: not granted'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('grant-Privacy_Accessibility')));
    await tester.tap(find.byKey(const Key('grant-Privacy_Accessibility')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Accessibility: granted'), findsOneWidget);
    // Screen Recording asks once and then offers the restart it needs.
    expect(find.byKey(const Key('restart')), findsNothing);
    await tester.tap(find.byKey(const Key('grant-Privacy_ScreenCapture')));
    await tester.pumpAndSettle();
    expect(perms.screenAsked, isTrue);
    expect(find.byKey(const Key('restart')), findsOneWidget);

    // Codex Computer Use: what it needs, one thing missing.
    await tester.ensureVisible(find.byKey(const Key('tool-codex-cu')));
    await tester.tap(find.byKey(const Key('tool-codex-cu')));
    await tester.pumpAndSettle();
    expect(find.text('✗ Computer Use plugin: Off'), findsOneWidget);
    // Claude's Mac control: a missing permission opens System Settings.
    await tester.ensureVisible(find.byKey(const Key('tool-claude-mac')));
    await tester.tap(find.byKey(const Key('tool-claude-mac')));
    await tester.pumpAndSettle();
    expect(find.text('✗ Peekaboo: Accessibility: Not granted'), findsOneWidget);
    await tester.tap(find.byKey(const Key('open-claude-mac-Privacy_Accessibility')));
    await tester.pumpAndSettle();
    expect(perms.opened, ['Privacy_Accessibility']);

    await tester.ensureVisible(find.byKey(const Key('next')));
    await tester.tap(find.byKey(const Key('next')));
    await started.future;
    final saved = jsonDecode(File('${tmp.path}/worker-types.json').readAsStringSync()) as Map;
    expect(saved['codex'], {'enabled': true, 'computer_use': true});
    expect(saved['claude'], {'enabled': true, 'mac': true});
    await tester.runAsync(server.close);
  });
}
