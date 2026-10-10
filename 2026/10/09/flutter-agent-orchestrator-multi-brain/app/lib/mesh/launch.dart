import 'dart:convert';
import 'dart:io';

import '../state/thread_view.dart' show Json;

/// What this app does in the network, chosen on the start screen (or from
/// `ORCH_*` variables, which skip it).
class LaunchConfig {
  LaunchConfig({
    this.brain = false,
    this.body = true,
    this.signaling = false,
    this.port = 8765,
    this.url = 'ws://localhost:8765',
    this.name = '',
    this.owner,
    this.assignOwner = false,
  });

  /// Runs an orchestrator that consoles talk to.
  bool brain;

  /// Lets a brain run workers on this machine.
  bool body;

  /// Runs the signaling server inside this app.
  bool signaling;

  /// The signaling server's port when [signaling].
  int port;

  /// The signaling server to join when not [signaling].
  String url;

  /// This app's name (the body id); empty picks one.
  String name;

  /// The brain this body belongs to (null: none, [self]: this app), applied
  /// after joining when [assignOwner].
  String? owner;
  bool assignOwner;

  /// The worker type a brain runs its orchestrator on (null: as before).
  String? orchestrator;

  static const self = '@self';

  /// Where this app joins: its own server, or [url].
  String get signalUrl => signaling ? 'ws://127.0.0.1:$port' : url;

  Json toJson() => {
    'brain': brain,
    'body': body,
    'signaling': signaling,
    'port': port,
    'url': url,
    'name': name,
    'owner': owner,
    'orchestrator': orchestrator,
  };

  static LaunchConfig fromJson(Json j) => LaunchConfig(
    brain: j['brain'] == true,
    body: j['body'] as bool? ?? true,
    signaling: j['signaling'] == true,
    port: (j['port'] as num?)?.toInt() ?? 8765,
    url: j['url'] as String? ?? 'ws://localhost:8765',
    name: j['name'] as String? ?? '',
    owner: j['owner'] as String?,
  )..orchestrator = j['orchestrator'] as String?;

  /// The last choice on the start screen, or defaults.
  static LaunchConfig load(String stateDir) {
    final f = File('$stateDir/launch.json');
    try {
      if (f.existsSync()) {
        return fromJson((jsonDecode(f.readAsStringSync()) as Map).cast());
      }
    } catch (_) {
      // Start from the defaults.
    }
    return LaunchConfig();
  }

  void save(String stateDir) {
    final f = File('$stateDir/launch.json');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(toJson()));
  }

  /// From `ORCH_ROLE` (comma list of brain, body, signal, console),
  /// `ORCH_SIGNAL_URL`, `ORCH_SIGNAL_PORT`, `ORCH_NAME` and `ORCH_OWNER`
  /// (the brain this body belongs to, as on the start screen; `-` for none);
  /// null when none of the first three is set (show the start screen). `ORCH_ROLE=brain` alone also makes a
  /// body; `console` alone makes neither.
  static LaunchConfig? fromEnv(Map<String, String> env) {
    String? v(String k) => env[k]?.isNotEmpty == true ? env[k] : null;
    if (v('ORCH_ROLE') == null &&
        v('ORCH_SIGNAL_URL') == null &&
        v('ORCH_NAME') == null) {
      return null;
    }
    final roles = {
      for (final r in (v('ORCH_ROLE') ?? '').split(','))
        if (r.trim().isNotEmpty) r.trim(),
    };
    final port = int.tryParse(v('ORCH_SIGNAL_PORT') ?? '') ?? 8765;
    return LaunchConfig(
      brain: roles.contains('brain'),
      body: roles.contains('body') || !roles.contains('console'),
      signaling: roles.contains('signal'),
      port: port,
      url: v('ORCH_SIGNAL_URL') ?? 'ws://127.0.0.1:$port',
      name: v('ORCH_NAME') ?? '',
      owner: v('ORCH_OWNER') == '-' ? null : v('ORCH_OWNER'),
      assignOwner: v('ORCH_OWNER') != null,
    );
  }
}
