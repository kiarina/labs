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
/// variables) it can also be a brain, a body, and the signaling server. All
/// join the signaling server and link to every brain over WebRTC.
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
  final signal = SignalClient(
    url: config.signalUrl,
    name: name,
    isBrain: config.brain,
    isBody: config.body,
  );
  final console = ConsoleMirror(local: local, signal: signal, isBrain: config.brain)
    ..preferred = env['ORCH_SELECT']
    ..signaling = config.signaling;
  if (env['ORCH_DUMP'] case final String path when path.isNotEmpty) {
    _dumpOnChange(console, path);
  }
  unawaited(_run(local, signal, console, orchestrator: config.orchestrator));
  if (config.assignOwner && config.body) {
    final owner = config.owner;
    unawaited(() async {
      while (!signal.connected) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final brain = owner == LaunchConfig.self ? signal.name : owner;
      await _assignOnStart(console, signal, '${signal.name}=${brain ?? ''}');
    }());
  }
  if (env['ORCH_ASSIGN'] case final String spec when spec.isNotEmpty) {
    unawaited(_assignOnStart(console, signal, spec));
  }
  return console;
}

Future<void> _run(
  LocalBody local,
  SignalClient signal,
  ConsoleMirror console, {
  String? orchestrator,
}) async {
  unawaited(signal.run());
  // The server may rename this app; the hub keys its own body by name.
  while (!signal.connected) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  local.name = signal.name;

  Hub? hub;
  ConsolePublisher? publisher;
  if (signal.isBrain) {
    // A brain that is not a body never runs workers on itself (even if an
    // older record says it owns itself).
    final h = hub = Hub(local)
      ..ownerOf = (b) => !signal.isBody && b == local.name ? null : signal.ownerOf(b);
    await h.start();
    // The worker type picked on the start screen.
    if (orchestrator != null && orchestrator != h.settings.orchestrator) {
      h.settings.orchestrator = orchestrator;
      await h.saveSettings();
    }
    final p = publisher = ConsolePublisher(h);
    signal.onReleaseRequest = (body) async => h.releaseBlocker(body);
    signal.addListener(h.ownershipChanged);
    // This brain's own console goes through the same messages as the others.
    final (brainEnd, consoleEnd) = loopbackPair(local.name, local.name);
    console.attachBrain(local.name, (a) => unawaited(h.handleAction(a)));
    consoleEnd.messages.listen((m) {
      if (m['t'] == 'console') console.handle(local.name, (m['m'] as Map).cast());
    });
    p.subscribe(brainEnd);
  }

  PeerManager(
    signal,
    log: signal.logStep,
    onPeer: (peer) {
      // As a brain: every linked app has a console, and a body to list.
      if (hub != null) {
        final body = RemoteBody(peer, const {});
        body.onHello = () => hub!.addRemoteBody(body);
        publisher!.subscribe(peer);
        // Any linked app's console may act, bodies or not (a console-only
        // app never says hello as a body).
        peer.messages.listen((m) {
          if (m['t'] == 'action') {
            unawaited(hub!.handleAction((m['a'] as Map).cast<String, dynamic>()));
          }
        });
      }
      // To a brain: mirror it, send it actions, serve it this body.
      if (signal.node(peer.name)?.brain == true) {
        console.attachBrain(peer.name, (a) => peer.send({'t': 'action', 'a': a}));
        peer.messages.listen((m) {
          if (m['t'] == 'console') console.handle(peer.name, (m['m'] as Map).cast());
        });
        if (signal.isBody) {
          BodyHost(local, peer, ownerOf: () => signal.ownerOf(local.name));
        }
        peer.closed.then((_) => console.detachBrain(peer.name));
      }
    },
  );
  // A console alone runs no agents.
  if (signal.isBrain || signal.isBody) await local.start();
}

/// `ORCH_ASSIGN=body=brain,body2=` moves bodies once they are in the roster
/// (for unattended checks; the body list in the console does the same).
Future<void> _assignOnStart(
  ConsoleMirror console,
  SignalClient signal,
  String spec,
) async {
  for (final pair in spec.split(',')) {
    final parts = pair.split('=');
    if (parts.length != 2) continue;
    final body = parts[0].trim(), brain = parts[1].trim();
    for (var i = 0; i < 300; i++) {
      final known = signal.node(body)?.online == true &&
          (brain.isEmpty || signal.node(brain)?.online == true);
      if (signal.connected && known) break;
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    final target = brain.isEmpty ? null : brain;
    if (signal.ownerOf(body) == target) continue;
    await console.assign(body, target);
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
