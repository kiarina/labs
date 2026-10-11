import 'dart:convert';
import 'dart:io';

import '../state/thread_view.dart' show Json;

/// What this app does in the network, chosen on the start screen (or from
/// `ORCH_*` variables, which skip it).
class LaunchConfig {
  LaunchConfig({
    List<String>? brains,
    this.body = true,
    this.signaling = false,
    this.port = 8765,
    this.url = 'ws://localhost:8765',
    this.name = '',
    List<String>? owners,
    this.assignOwner = false,
  }) : owners = owners ?? [],
       brains = brains ?? [];

  /// The brains this app runs, by name: each joins the signaling server on
  /// its own and has its own links, like a brain on another app. Their
  /// settings are in `brains/<name>/brain.json`.
  List<String> brains;

  /// Lets brains run workers on this machine.
  bool body;

  /// Runs the signaling server inside this app.
  bool signaling;

  /// The signaling server's port when [signaling].
  int port;

  /// The signaling server to join when not [signaling].
  String url;

  /// This app's name (its console's, and the body id); empty picks one.
  String name;

  /// The brains this body belongs to (this app's or others'; several: a
  /// shared body), applied after joining when [assignOwner].
  List<String> owners;
  bool assignOwner;

  /// A brain's own folder in the app's state folder.
  static String brainDir(String stateDir, String brain) => '$stateDir/brains/$brain';

  /// Where this app joins: its own server, or [url].
  String get signalUrl => signaling ? 'ws://127.0.0.1:$port' : url;

  Json toJson() => {
    'brains': brains,
    'body': body,
    'signaling': signaling,
    'port': port,
    'url': url,
    'name': name,
    'owners': owners,
  };

  static LaunchConfig fromJson(Json j) => LaunchConfig(
    brains: [for (final b in j['brains'] as List? ?? const []) '$b'],
    body: j['body'] as bool? ?? true,
    signaling: j['signaling'] == true,
    port: (j['port'] as num?)?.toInt() ?? 8765,
    url: j['url'] as String? ?? 'ws://localhost:8765',
    name: j['name'] as String? ?? '',
    owners: j.containsKey('owners')
        ? [for (final o in j['owners'] as List) '$o']
        : [if (j['owner'] case final String o) o],
  );

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

  /// From `ORCH_BRAINS` (comma list of the brains this app runs),
  /// `ORCH_ROLE` (comma list of body, signal, console), `ORCH_SIGNAL_URL`,
  /// `ORCH_SIGNAL_PORT`, `ORCH_NAME` (this app's name) and `ORCH_OWNER` (the
  /// brains this body belongs to, comma-separated; `-` for none); null when
  /// none of `ORCH_BRAINS`, `ORCH_ROLE`, `ORCH_SIGNAL_URL` and `ORCH_NAME` is
  /// set (show the start screen). With no role and no brains, the app is a
  /// body; `console` alone makes it neither.
  static LaunchConfig? fromEnv(Map<String, String> env) {
    String? v(String k) => env[k]?.isNotEmpty == true ? env[k] : null;
    if (v('ORCH_BRAINS') == null &&
        v('ORCH_ROLE') == null &&
        v('ORCH_SIGNAL_URL') == null &&
        v('ORCH_NAME') == null) {
      return null;
    }
    List<String> list(String k) => [
      for (final x in (v(k) ?? '').split(','))
        if (x.trim().isNotEmpty && x.trim() != '-') x.trim(),
    ];
    final roles = list('ORCH_ROLE').toSet();
    final brains = list('ORCH_BRAINS');
    final port = int.tryParse(v('ORCH_SIGNAL_PORT') ?? '') ?? 8765;
    return LaunchConfig(
      brains: brains,
      body: roles.contains('body') || (roles.isEmpty && brains.isEmpty),
      signaling: roles.contains('signal'),
      port: port,
      url: v('ORCH_SIGNAL_URL') ?? 'ws://127.0.0.1:$port',
      name: v('ORCH_NAME') ?? '',
      owners: list('ORCH_OWNER'),
      assignOwner: v('ORCH_OWNER') != null,
    );
  }
}
