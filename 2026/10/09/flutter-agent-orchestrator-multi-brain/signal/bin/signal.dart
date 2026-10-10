// The signaling server on its own (see lib/signal_server.dart). An app can
// also run it inside itself (the start screen's "Signaling").
//
//   dart run bin/signal.dart [port]     PORT also sets the port (default 8765)
//   OWNERS_FILE=path                    keeps body ownership across restarts

import 'dart:io';

import 'package:orchestrator_signal/signal_server.dart';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  final port =
      int.tryParse(args.isNotEmpty ? args.first : env['PORT'] ?? '') ?? 8765;
  final owners = env['OWNERS_FILE'];
  await SignalServer(
    port: port,
    ownersFile: owners == null || owners.isEmpty ? null : File(owners),
  ).start();
}
