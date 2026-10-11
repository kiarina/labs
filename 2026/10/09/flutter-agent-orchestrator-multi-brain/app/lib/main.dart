import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:orchestrator_signal/signal_server.dart' show SignalServer;

import 'body/body.dart';
import 'console/console.dart';
import 'mesh/launch.dart';
import 'mesh/peer.dart';
import 'mesh/signal.dart';
import 'orchestrator/hub.dart';
import 'ui/home_page.dart';
import 'ui/launch_page.dart';
import 'ui/theme.dart';

/// Every app has a console; on the start screen (or from `ORCH_*`
/// variables) it can also run brains (any number), be a body, and run the
/// signaling server. The app and each of its brains join the signaling
/// server on their own and have their own WebRTC links: an app links to
/// every brain, its own included, the same way.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final stateDir =
      env['ORCH_STATE_DIR'] ??
      '${env['HOME']}/Library/Application Support/com.kiarina.labs.agentOrchestratorMultiBrain';
  runApp(OrchestratorApp(stateDir: stateDir, fromEnv: LaunchConfig.fromEnv(env)));
}

/// Starts this app as [config] chose, after the signaling server (if any)
/// is up, and returns the console.
ConsoleMirror _boot(LaunchConfig config, String stateDir) {
  final env = Platform.environment;
  final name = config.name.isNotEmpty ? config.name : generateName();
  final local = LocalBody(name: name, stateDir: stateDir);
  // Its project folder is where this app's brains work by default.
  if (config.body) local.loadConfig();
  final signal = SignalClient(
    url: config.signalUrl,
    name: name,
    isBrain: false,
    isBody: config.body,
  );
  final console = ConsoleMirror(local: local, signal: signal, localBrains: config.brains)
    ..preferred = env['ORCH_SELECT'] ?? config.brains.firstOrNull
    ..signaling = config.signaling;
  if (env['ORCH_DUMP'] case final String path when path.isNotEmpty) {
    _dumpOnChange(console, path);
  }
  unawaited(_runApp(local, signal, console));
  final hubs = [
    for (final b in config.brains)
      _runBrain(b, config, stateDir, local, console),
  ];
  if (env['ORCH_TOOLS'] case final String path when path.isNotEmpty) {
    unawaited(Future.wait(hubs).then((h) => _toolsOnStart(h, path)));
  }
  if (config.assignOwner && config.body) {
    unawaited(() async {
      while (!signal.connected) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      await _assignOnStart(console, signal, '${signal.name}=${config.owners.join('+')}');
    }());
  }
  if (env['ORCH_ASSIGN'] case final String spec when spec.isNotEmpty) {
    unawaited(_assignOnStart(console, signal, spec));
  }
  if (env['ORCH_CONFIGURE_BRAIN'] case final String spec when spec.isNotEmpty) {
    unawaited(_configureBrainOnStart(console, spec));
  }
  if (env['ORCH_PAUSE'] case final String spec when spec.isNotEmpty) {
    unawaited(() async {
      await _pauseOnStart(console, spec);
      if (env['ORCH_CONFIGURE'] case final String c when c.isNotEmpty) {
        await _configureOnStart(console, c);
      }
    }());
  }
  return console;
}

/// The app itself: its console (mirrors every brain it links to) and, if a
/// body, its workers (served to the brains it belongs to).
Future<void> _runApp(LocalBody local, SignalClient signal, ConsoleMirror console) async {
  unawaited(signal.run());
  // The server may rename this app.
  while (!signal.connected) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  local.name = signal.name;
  PeerManager(
    signal,
    log: signal.logStep,
    onPeer: (peer) {
      // Every peer of an app is a brain: mirror it, send it actions, serve
      // it this body.
      console.attachBrain(
        peer.name,
        (a) => peer.send({'t': 'action', 'a': a}),
        RequestLink(peer).call,
      );
      peer.messages.listen((m) {
        if (m['t'] == 'console') console.handle(peer.name, (m['m'] as Map).cast());
      });
      if (signal.isBody) {
        BodyHost(local, peer, ownersOf: () => signal.ownersOf(local.name));
      }
      peer.closed.then((_) => console.detachBrain(peer.name));
    },
  );
  // A console alone runs no agents.
  if (signal.isBody) await local.start();
}

/// One brain of this app: joins the signaling server under its own name,
/// links to every app (bodies and consoles, its own app included) and runs
/// its orchestrator in a process of its own.
Future<Hub> _runBrain(
  String name,
  LaunchConfig config,
  String stateDir,
  LocalBody local,
  ConsoleMirror console,
) async {
  final signal = SignalClient(
    url: config.signalUrl,
    name: name,
    isBrain: true,
    isBody: false,
  );
  unawaited(signal.run());
  while (!signal.connected) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final hub = Hub(
    name: signal.name,
    stateDir: LaunchConfig.brainDir(stateDir, name),
    defaultDir: config.body ? () => local.projectDir : null,
    log: local.logClient,
  )..ownersOf = signal.ownersOf;
  console.brainLinks[signal.name] = signal;
  // Its agent starts in the background; consoles show it starting.
  unawaited(hub.start());
  final publisher = ConsolePublisher(hub);
  signal.onReleaseRequest = (body) async => hub.releaseBlocker(body);
  signal.addListener(hub.ownershipChanged);
  PeerManager(
    signal,
    log: signal.logStep,
    onPeer: (peer) {
      // Every linked app has a console; a body says hello as one.
      final body = RemoteBody(peer, const {});
      body.onHello = () => hub.addRemoteBody(body);
      publisher.subscribe(peer);
      peer.messages.listen((m) {
        if (m['t'] == 'action') {
          unawaited(hub.handleAction((m['a'] as Map).cast<String, dynamic>()));
        }
      });
      RequestLink.serve(peer, hub.request);
    },
  );
  return hub;
}

/// `ORCH_PAUSE=body,body2` pauses bodies through their brains once this
/// console sees them (for unattended checks; the pause button in the body
/// list does the same).
Future<void> _pauseOnStart(ConsoleMirror console, String spec) async {
  for (final name in spec.split(',').map((s) => s.trim())) {
    for (var i = 0; i < 300; i++) {
      final b = console.allBodies.where((b) => b.name == name).firstOrNull;
      if (b != null && console.canPause(b)) {
        console.setPaused(b, true);
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }
}

/// `ORCH_CONFIGURE=body=path.json` (after `ORCH_PAUSE`) gives a paused body
/// new agents (a `worker-types.json`) through its brain once it shows as
/// paused, and puts the outcome in the console's notice (for unattended
/// checks; the body's settings dialog does the same).
Future<void> _configureOnStart(ConsoleMirror console, String spec) async {
  final i = spec.indexOf('=');
  final name = spec.substring(0, i), path = spec.substring(i + 1);
  for (var n = 0; n < 300; n++) {
    final b = console.allBodies.where((b) => b.name == name).firstOrNull;
    if (b != null && (b.view?.paused ?? false)) {
      try {
        await console.bodyRequest(b, 'body/configure', {
          'config': jsonDecode(await File(path).readAsString()),
        });
        console.say('configured $name');
      } catch (e) {
        console.say('could not configure $name: $e');
      }
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// `ORCH_CONFIGURE_BRAIN=brain=path.json` gives a brain new settings (a
/// `brain.json`) once this console sees it ready, and puts the outcome in
/// the console's notice (for unattended checks; the brain's settings dialog
/// does the same).
Future<void> _configureBrainOnStart(ConsoleMirror console, String spec) async {
  final i = spec.indexOf('=');
  final name = spec.substring(0, i), path = spec.substring(i + 1);
  for (var n = 0; n < 300; n++) {
    if (console.brainAgentOf(name)['ready'] == true) {
      try {
        await console.brainRequest(name, 'brain/configure', {
          'config': jsonDecode(await File(path).readAsString()),
        });
        console.say('configured $name');
      } catch (e) {
        console.say('could not configure $name: $e');
      }
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

/// `ORCH_TOOLS=steps.json` makes this app's brains call their orchestrator
/// tools themselves, without a model (for unattended checks that spend no
/// tokens): a list of `{brain, tool, args, delay_ms}` (no brain: the first),
/// each run once the body it names is one of that brain's, after its delay. Each result is appended to
/// `steps.json.out.jsonl`.
Future<void> _toolsOnStart(List<Hub> hubs, String path) async {
  final steps = (jsonDecode(await File(path).readAsString()) as List).cast<Map>();
  final out = File('$path.out.jsonl');
  for (final step in steps) {
    final hub = hubs.where((h) => h.name == step['brain']).firstOrNull ?? hubs.first;
    final args = (step['args'] as Map? ?? const {}).cast<String, dynamic>();
    if (args['body'] case final String body) {
      for (var i = 0; i < 300 && !hub.ownBodies.any((b) => b.name == body); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
    await Future<void>.delayed(Duration(milliseconds: (step['delay_ms'] as num?)?.toInt() ?? 0));
    final tool = step['tool'] as String;
    final result = tool == 'fetch_image'
        ? (await hub.toolResult(tool, args))
        : await hub.callTool(tool, args);
    await out.writeAsString(
      '${jsonEncode({'at': DateTime.now().toIso8601String(), 'brain': hub.name, 'tool': tool, 'result': result})}\n',
      mode: FileMode.append,
    );
  }
}

/// `ORCH_ASSIGN=body=brain,body2=brain-a+brain-b,body3=` sets the brains
/// bodies belong to once they are in the roster (`+` between brains; empty:
/// none) (for unattended checks; the body list in the console does the
/// same).
Future<void> _assignOnStart(
  ConsoleMirror console,
  SignalClient signal,
  String spec,
) async {
  for (final pair in spec.split(',')) {
    final parts = pair.split('=');
    if (parts.length != 2) continue;
    final body = parts[0].trim();
    final brains = [
      for (final b in parts[1].split('+'))
        if (b.trim().isNotEmpty) b.trim(),
    ];
    for (var i = 0; i < 300; i++) {
      final known = signal.node(body)?.online == true &&
          brains.every((b) => signal.node(b)?.online == true);
      if (signal.connected && known) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final now = signal.ownersOf(body);
    if (now.length == brains.length && now.every(brains.contains)) continue;
    await console.assign(body, brains);
  }
}

/// Writes [ConsoleMirror.digest] to [path] whenever the console changes
/// (at most twice a second).
void _dumpOnChange(ConsoleMirror console, String path) {
  Timer? timer;
  void write() {
    timer = null;
    File(path).writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(console.digest()),
    );
  }

  void schedule() => timer ??= Timer(const Duration(milliseconds: 500), write);
  console.addListener(schedule);
  // Transcript operations notify the thread views, not the console.
  Timer.periodic(const Duration(seconds: 2), (_) => schedule());
}

class OrchestratorApp extends StatefulWidget {
  const OrchestratorApp({super.key, required this.stateDir, this.fromEnv});

  final String stateDir;

  /// Set by `ORCH_*` variables: start right away, without the start screen.
  final LaunchConfig? fromEnv;

  @override
  State<OrchestratorApp> createState() => _OrchestratorAppState();
}

class _OrchestratorAppState extends State<OrchestratorApp> {
  ConsoleMirror? _console;
  SignalServer? _server;
  String? _error;

  File get _ownersFile => File('${widget.stateDir}/signal-owners.json');

  File get _typesFile => File(
    Platform.environment['ORCH_WORKER_TYPES'] ?? '${widget.stateDir}/worker-types.json',
  );

  @override
  void initState() {
    super.initState();
    if (widget.fromEnv case final config?) unawaited(_startFromEnv(config));
  }

  @override
  void dispose() {
    unawaited(_server?.close());
    super.dispose();
  }

  Future<void> _startFromEnv(LaunchConfig config) async {
    SignalServer? server;
    if (config.signaling) {
      server = SignalServer(port: config.port, ownersFile: _ownersFile);
      try {
        await server.start();
      } on SocketException catch (e) {
        setState(() => _error =
            'Could not start signaling on port ${config.port}: it is in use '
            '(${e.osError?.message ?? e.message}).');
        return;
      }
    }
    _started(config, server, save: false);
  }

  void _started(LaunchConfig config, SignalServer? server, {bool save = true}) {
    if (save) config.save(widget.stateDir);
    setState(() {
      _server = server;
      _console = _boot(config, widget.stateDir);
    });
  }

  @override
  Widget build(BuildContext context) {
    final console = _console;
    return MaterialApp(
      title: 'Agent Orchestrator',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: console != null
          ? HomePage(console: console)
          : LaunchPage(
              key: ValueKey(_error),
              initial: widget.fromEnv ?? LaunchConfig.load(widget.stateDir),
              ownersFile: _ownersFile,
              typesFile: _typesFile,
              stateDir: widget.stateDir,
              error: _error,
              onStart: _started,
            ),
    );
  }
}
