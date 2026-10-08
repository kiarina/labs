import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import 'body/body.dart';
import 'console/console.dart';
import 'mesh/peer.dart';
import 'orchestrator/hub.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

/// Every app has a console and a body. One app is also the brain
/// (`ORCH_ROLE=brain`, the default without `ORCH_BRAIN_URL`); the others
/// join it (`ORCH_BRAIN_URL=ws://host:port`).
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final brainUrl = env['ORCH_BRAIN_URL'];
  final role = env['ORCH_ROLE'] ?? (brainUrl == null ? 'brain' : 'body');
  final isBrain = role == 'brain';
  final name = env['ORCH_NAME']?.isNotEmpty == true
      ? env['ORCH_NAME']!
      : generateName();
  final stateDir =
      env['ORCH_STATE_DIR'] ??
      '${env['HOME']}/Library/Application Support/com.kiarina.labs.agentOrchestratorMesh';
  final local = LocalBody(name: name, stateDir: stateDir);
  final console = ConsoleMirror(local: local, isBrain: isBrain);
  runApp(OrchestratorApp(console: console));
  if (env['ORCH_DUMP'] case final String path when path.isNotEmpty) {
    _dumpOnChange(console, path);
  }
  if (isBrain) {
    unawaited(_runBrain(local, console));
  } else {
    if (brainUrl == null) {
      console.onDisconnected('set ORCH_BRAIN_URL to join a brain');
      return;
    }
    unawaited(_runBody(local, console, brainUrl));
  }
}

Future<void> _runBrain(LocalBody local, ConsoleMirror console) async {
  final hub = Hub(local);
  await hub.start();
  final publisher = ConsolePublisher(hub);

  // The brain's own console goes through the same messages as the others.
  final (brainEnd, consoleEnd) = loopbackPair(local.name, local.name);
  consoleEnd.messages.listen((m) {
    if (m['t'] == 'console') console.handle((m['m'] as Map).cast());
  });
  console.sendAction = (a) => unawaited(hub.handleAction(a));
  publisher.subscribe(brainEnd);

  final port = int.tryParse(Platform.environment['ORCH_PORT'] ?? '') ?? 8765;
  final server = SignalingServer(
    name: local.name,
    port: port,
    onPeer: (peer) {
      final body = RemoteBody(peer, const {});
      body.onHello = () {
        hub.addRemoteBody(body);
        publisher.subscribe(peer);
      };
    },
  )..claimName = hub.claimName;
  try {
    await server.start();
    console.onConnected('brain · port $port');
  } catch (e) {
    console.onConnected('brain · signaling failed: $e');
  }
  await local.start();
}

Future<void> _runBody(
  LocalBody local,
  ConsoleMirror console,
  String url,
) async {
  unawaited(local.start());
  while (true) {
    console.onDisconnected('connecting to $url');
    try {
      final peer = await joinBrain(url, local.name, log: console.logStep);
      local.name = peer.selfName ?? local.name;
      peer.messages.listen((m) {
        if (m['t'] == 'console') console.handle((m['m'] as Map).cast());
      });
      console.sendAction = (a) => peer.send({'t': 'action', 'a': a});
      BodyHost(local, peer);
      console.onConnected('body of ${peer.name}');
      await peer.closed;
      console.sendAction = null;
      console.onDisconnected('lost the brain ${peer.name}');
    } catch (e) {
      console.onDisconnected('$e');
    }
    await Future<void>.delayed(const Duration(seconds: 3));
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
