import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'body/body.dart';
import 'console/console.dart';
import 'mesh/peer.dart';
import 'mesh/signal.dart';
import 'orchestrator/hub.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

/// Every app has a console and a body; some are also brains
/// (`ORCH_ROLE=brain`). All join the signaling server (`ORCH_SIGNAL_URL`,
/// `signal/bin/signal.dart`) and link to every brain over WebRTC.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final isBrain = env['ORCH_ROLE'] == 'brain';
  final name = env['ORCH_NAME']?.isNotEmpty == true
      ? env['ORCH_NAME']!
      : generateName();
  final stateDir =
      env['ORCH_STATE_DIR'] ??
      '${env['HOME']}/Library/Application Support/com.kiarina.labs.agentOrchestratorMultiBrain';
  final local = LocalBody(name: name, stateDir: stateDir);
  final signal = SignalClient(
    url: env['ORCH_SIGNAL_URL'] ?? 'ws://127.0.0.1:8765',
    name: name,
    isBrain: isBrain,
  );
  final console = ConsoleMirror(local: local, signal: signal, isBrain: isBrain)
    ..preferred = env['ORCH_SELECT'];
  runApp(OrchestratorApp(console: console));
  if (env['ORCH_DUMP'] case final String path when path.isNotEmpty) {
    _dumpOnChange(console, path);
  }
  unawaited(_run(local, signal, console));
  if (env['ORCH_ASSIGN'] case final String spec when spec.isNotEmpty) {
    unawaited(_assignOnStart(console, signal, spec));
  }
}

Future<void> _run(
  LocalBody local,
  SignalClient signal,
  ConsoleMirror console,
) async {
  unawaited(signal.run());
  // The server may rename this app; the hub keys its own body by name.
  while (!signal.connected) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  local.name = signal.name;

  Hub? hub;
  ConsolePublisher? publisher;
  if (signal.isBrain) {
    final h = hub = Hub(local)..ownerOf = signal.ownerOf;
    await h.start();
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
      }
      // To a brain: mirror it, send it actions, serve it this body.
      if (signal.node(peer.name)?.brain == true) {
        console.attachBrain(peer.name, (a) => peer.send({'t': 'action', 'a': a}));
        peer.messages.listen((m) {
          if (m['t'] == 'console') console.handle(peer.name, (m['m'] as Map).cast());
        });
        BodyHost(local, peer, ownerOf: () => signal.ownerOf(local.name));
        peer.closed.then((_) => console.detachBrain(peer.name));
      }
    },
  );
  await local.start();
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
    await console.assign(body, brain.isEmpty ? null : brain);
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

class OrchestratorApp extends StatelessWidget {
  const OrchestratorApp({super.key, required this.console});

  final ConsoleMirror console;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Agent Orchestrator',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: HomePage(console: console),
    );
  }
}
