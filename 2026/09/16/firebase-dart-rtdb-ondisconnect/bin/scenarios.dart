// Drives bin/client.dart through disconnect scenarios and measures how fast
// the server-side presence follows.
//
// The client talks to the RTDB emulator through an in-process TCP proxy so
// the network can be cut in two ways:
//   reset      close both sockets (the server sees the TCP close)
//   blackhole  stop forwarding but keep the sockets open (half-open link)
//
// An observer polls /presence/{uid} over REST as the emulator owner.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

final _env = Platform.environment;
final _client = _env['CLIENT'] ?? 'build/client';
final _dbHost = _env['DB_HOST'] ?? '127.0.0.1';
final _dbPort = int.parse(_env['DB_PORT'] ?? '9000');
final _authEmulator = _env['AUTH_EMULATOR'] ?? '127.0.0.1:9099';
final _blackholeSeconds = int.parse(_env['BLACKHOLE_SECONDS'] ?? '90');
final _flaps = int.parse(_env['FLAPS'] ?? '10');
// The host the emulator advertises in its handshake (its configured host,
// whatever address the client used).
final _advertised = _env['ADVERTISED_HOST'] ?? '127.0.0.1:9000';
// Must keep the advertised string length: the handshake is rewritten in place.
final _proxyPort = int.parse(_env['PROXY_PORT'] ?? '9001');
const _ns = 'demo-lab-default-rtdb';

final results = <String, Object?>{};

void log(String message) => stderr.writeln(
  '[${DateTime.now().toIso8601String().substring(11, 23)}] $message',
);

class ProxyPair {
  final Socket client;
  final Socket upstream;
  bool blackhole = false;
  ProxyPair(this.client, this.upstream);
  void destroy() {
    client.destroy();
    upstream.destroy();
  }
}

class Proxy {
  late final ServerSocket _server;
  final _pairs = <ProxyPair>[];
  bool accepting = true;
  int accepted = 0;
  int hostRewrites = 0;

  int get port => _server.port;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, _proxyPort);
    // The server's handshake carries a host ("h") that clients cache and
    // reconnect to directly. Point it back at the proxy, keeping the length
    // so the WebSocket frame header stays valid.
    final from = utf8.encode('"h":"$_advertised"');
    final to = utf8.encode('"h":"127.0.0.1:$_proxyPort"');
    if (from.length != to.length) {
      throw StateError(
        '"127.0.0.1:PROXY_PORT" must be as long as ADVERTISED_HOST',
      );
    }
    _server.listen((client) async {
      if (!accepting) {
        client.destroy();
        return;
      }
      accepted++;
      final upstream = await Socket.connect(_dbHost, _dbPort);
      final pair = ProxyPair(client, upstream);
      _pairs.add(pair);
      void drop() {
        if (pair.blackhole) {
          // A half-open link: the server never learns that the client left,
          // so keep the upstream side open until release().
          client.destroy();
          return;
        }
        pair.destroy();
        _pairs.remove(pair);
      }

      client.listen(
        (d) => pair.blackhole ? null : upstream.add(d),
        onDone: drop,
        onError: (_) => drop(),
      );
      upstream.listen(
        (d) {
          if (pair.blackhole) return;
          final i = _indexOf(d, from);
          if (i >= 0) {
            d = Uint8List.fromList(d)..setRange(i, i + to.length, to);
            hostRewrites++;
          }
          client.add(d);
        },
        onDone: drop,
        onError: (_) => drop(),
      );
    });
  }

  int get open => _pairs.length;

  /// Stops forwarding on the current connections only, keeping them open.
  List<ProxyPair> blackholeCurrent() {
    final current = List.of(_pairs);
    for (final p in current) {
      p.blackhole = true;
    }
    return current;
  }

  void release(List<ProxyPair> pairs) {
    for (final p in pairs) {
      p.destroy();
      _pairs.remove(p);
    }
  }

  void resetAll() => release(List.of(_pairs));
}

int _indexOf(List<int> haystack, List<int> needle) {
  outer:
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}

class ClientProcess {
  final Process process;
  final events = <Map<String, dynamic>>[];
  final _controller = StreamController<Map<String, dynamic>>.broadcast();

  ClientProcess(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            final e = jsonDecode(line) as Map<String, dynamic>;
            events.add(e);
            _controller.add(e);
            if (e['event'] != 'auth_http') {
              log('  client ${e['event']} ${e['value'] ?? e['count'] ?? ''}');
            }
          } catch (_) {
            log('  client: $line');
          }
        });
    process.stderr
        .transform(utf8.decoder)
        .listen((s) => log('  client stderr: $s'));
  }

  static Future<ClientProcess> start(
    String storage,
    int proxyPort,
    String session,
  ) async {
    final p = await Process.start(
      _client,
      [],
      environment: {
        'STORAGE_PATH': storage,
        'DATABASE_URL': 'http://127.0.0.1:$proxyPort/?ns=$_ns',
        'AUTH_EMULATOR': _authEmulator,
        'SESSION': session,
        'EMAIL': _env['EMAIL'] ?? 'body@example.com',
      },
    );
    return ClientProcess(p);
  }

  Future<Map<String, dynamic>> waitFor(
    String event, {
    bool Function(Map<String, dynamic>)? where,
    Duration timeout = const Duration(seconds: 30),
  }) {
    return _controller.stream
        .firstWhere((e) => e['event'] == event && (where == null || where(e)))
        .timeout(timeout);
  }

  int count(String event, [Object? value]) => events
      .where(
        (e) => e['event'] == event && (value == null || e['value'] == value),
      )
      .length;

  void send(String command) => process.stdin.writeln(command);
}

final _http = HttpClient();

Future<Map<String, dynamic>?> readPresence(String uid) async {
  final req = await _http.getUrl(
    Uri.parse('http://$_dbHost:$_dbPort/presence/$uid.json?ns=$_ns'),
  );
  req.headers.set('Authorization', 'Bearer owner');
  final res = await req.close();
  final body = await res.transform(utf8.decoder).join();
  return jsonDecode(body) as Map<String, dynamic>?;
}

/// Polls until the presence matches, returning elapsed milliseconds or null.
Future<int?> waitPresence(String uid, bool online, Duration timeout) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    final p = await readPresence(uid);
    if (p != null && p['online'] == online) return sw.elapsedMilliseconds;
    await Future.delayed(const Duration(milliseconds: 100));
  }
  return null;
}

Future<void> main() async {
  final storage = Directory.systemTemp
      .createTempSync('firebase-dart-lab-')
      .path;
  final proxy = Proxy();
  await proxy.start();
  log('proxy :${proxy.port} -> $_dbHost:$_dbPort, storage $storage');

  // --- S1: first sign-in, rules, graceful shutdown -------------------------
  log('S1 graceful');
  var c = await ClientProcess.start(storage, proxy.port, 's1');
  final ready = await c.waitFor('ready');
  final uid = ready['uid'] as String;
  await c.waitFor('registered');
  final s1Online = await waitPresence(uid, true, const Duration(seconds: 5));
  c.send('probe');
  final probe = await c.waitFor('probe');
  c.send('graceful');
  final sw = Stopwatch()..start();
  final done = await c.waitFor('graceful_done');
  final s1Offline = await waitPresence(uid, false, const Duration(seconds: 5));
  await c.process.exitCode;
  results['S1_graceful'] = {
    'signed_in': c.count('signed_in') == 1,
    'online_seen': s1Online != null,
    'rules_denied_other_uid': probe['denied'],
    'graceful_done_ms': done['ms'],
    'offline_after_ms': s1Offline == null ? null : sw.elapsedMilliseconds,
    'exit_code': await c.process.exitCode,
  };

  // --- S2: restart restores the session, refresh, then SIGKILL -------------
  log('S2 restore + refresh + SIGKILL');
  c = await ClientProcess.start(storage, proxy.port, 's2');
  final restored = await Future.any([
    c.waitFor('restored').then((_) => true),
    c.waitFor('signed_in').then((_) => false),
  ]);
  await c.waitFor('registered');
  c.send('refresh');
  await c.waitFor('refreshed');
  c.send('touch');
  final touched = await c
      .waitFor('touched')
      .then((_) => true, onError: (_) => false);
  await waitPresence(uid, true, const Duration(seconds: 5));
  final killed = Stopwatch()..start();
  c.process.kill(ProcessSignal.sigkill);
  await c.process.exitCode;
  final s2Offline = await waitPresence(
    uid,
    false,
    const Duration(seconds: 120),
  );
  results['S2_sigkill'] = {
    'session_restored_from_storage': restored,
    'network_signin_calls': c.events
        .where(
          (e) => e['event'] == 'auth_http' && '${e['path']}'.contains('signIn'),
        )
        .length,
    'refresh_then_write_ok': touched,
    'offline_after_kill_ms': s2Offline == null
        ? null
        : killed.elapsedMilliseconds,
  };

  // --- S3: connection reset while running, then automatic recovery ---------
  log('S3 reset + recovery');
  c = await ClientProcess.start(storage, proxy.port, 's3');
  await c.waitFor('registered');
  await waitPresence(uid, true, const Duration(seconds: 5));
  final lost = c.waitFor('connected', where: (e) => e['value'] == false);
  final reRegistered = c.waitFor(
    'registered',
    where: (e) => e['count'] == 2,
    timeout: const Duration(seconds: 120),
  );
  proxy.accepting = false;
  final cut = Stopwatch()..start();
  proxy.resetAll();
  final s3Offline = await waitPresence(uid, false, const Duration(seconds: 30));
  final s3OfflineMs = s3Offline == null ? null : cut.elapsedMilliseconds;
  await lost;
  final clientNoticedMs = cut.elapsedMilliseconds;
  await Future.delayed(const Duration(seconds: 3));
  proxy.accepting = true;
  final restoredAt = Stopwatch()..start();
  await reRegistered;
  final s3Online = await waitPresence(uid, true, const Duration(seconds: 30));
  results['S3_reset'] = {
    'server_offline_after_ms': s3OfflineMs,
    'client_noticed_within_ms': clientNoticedMs,
    'online_again_after_restore_ms': s3Online == null
        ? null
        : restoredAt.elapsedMilliseconds,
  };

  // --- S4a: half-open link without an application watchdog ---------------
  log('S4a blackhole for ${_blackholeSeconds}s');
  final beforeConnectedFalse = c.count('connected', false);
  var held = proxy.blackholeCurrent();
  final hole = Stopwatch()..start();
  int? s4ServerOffline;
  int? s4ClientNoticed;
  while (hole.elapsed.inSeconds < _blackholeSeconds) {
    await Future.delayed(const Duration(milliseconds: 250));
    if (s4ServerOffline == null) {
      final p = await readPresence(uid);
      if (p?['online'] == false) s4ServerOffline = hole.elapsedMilliseconds;
    }
    if (s4ClientNoticed == null &&
        c.count('connected', false) > beforeConnectedFalse) {
      s4ClientNoticed = hole.elapsedMilliseconds;
    }
  }
  final regBeforeHeal = c.count('registered');
  proxy.release(held);
  final healed = Stopwatch()..start();
  await c.waitFor(
    'registered',
    where: (e) => (e['count'] as int) > regBeforeHeal,
    timeout: const Duration(seconds: 60),
  );
  final s4Online = await waitPresence(uid, true, const Duration(seconds: 30));
  results['S4a_blackhole'] = {
    'blackhole_seconds': _blackholeSeconds,
    'server_offline_after_ms': s4ServerOffline,
    'client_noticed_after_ms': s4ClientNoticed,
    'reregistered_and_online_after_release_ms': s4Online == null
        ? null
        : healed.elapsedMilliseconds,
  };

  // --- S4b: half-open link with an application watchdog --------------------
  // The client writes a heartbeat every 5 s with a 5 s timeout and, on
  // timeout, forces a reconnect (goOffline + goOnline). The stale connection
  // is then released to see whether its onDisconnect overwrites the new
  // connection's "online".
  log('S4b blackhole with watchdog');
  c.send('watchdog');
  await c.waitFor('watchdog_on');
  await Future.delayed(const Duration(seconds: 6));
  final regBeforeHole = c.count('registered');
  held = proxy.blackholeCurrent();
  final hole2 = Stopwatch()..start();
  final timeoutEvent = await c.waitFor(
    'watchdog_timeout',
    timeout: const Duration(seconds: 60),
  );
  final detectedMs = hole2.elapsedMilliseconds;
  await c.waitFor(
    'registered',
    where: (e) => (e['count'] as int) > regBeforeHole,
    timeout: const Duration(seconds: 60),
  );
  final reRegisteredMs = hole2.elapsedMilliseconds;
  final onlineOnNewConnection = (await readPresence(uid))?['online'] == true;
  final staleStillOpen = held.where((p) => proxy._pairs.contains(p)).length;
  proxy.release(held);
  final afterRelease = Stopwatch()..start();
  int? overwrittenMs;
  while (afterRelease.elapsed.inSeconds < 5) {
    if ((await readPresence(uid))?['online'] == false) {
      overwrittenMs = afterRelease.elapsedMilliseconds;
      break;
    }
    await Future.delayed(const Duration(milliseconds: 100));
  }
  await Future.delayed(const Duration(seconds: 3));
  final s4bFinal = await readPresence(uid);
  results['S4b_blackhole_watchdog'] = {
    'watchdog_detected_after_ms': detectedMs,
    'watchdog_event': timeoutEvent['error'],
    'reregistered_after_ms': reRegisteredMs,
    'online_on_new_connection': onlineOnNewConnection,
    'stale_connections_open_at_release': staleStillOpen,
    'stale_ondisconnect_overwrote_online_after_ms': overwrittenMs,
    'final_online_after_release': s4bFinal?['online'],
  };
  c.send('watchdog_off');

  // Restore a clean online state for the flap test.
  proxy.resetAll();
  await waitPresence(uid, true, const Duration(seconds: 60));

  // --- S5: repeated flaps ----------------------------------------------------
  log('S5 $_flaps flaps');
  final regBefore = c.count('registered');
  var flapOfflineSeen = 0;
  var flapOnlineSeen = 0;
  for (var i = 0; i < _flaps; i++) {
    final next = c.waitFor(
      'registered',
      where: (e) => (e['count'] as int) > regBefore + i,
      timeout: const Duration(seconds: 60),
    );
    proxy.resetAll();
    if (await waitPresence(uid, false, const Duration(seconds: 10)) != null) {
      flapOfflineSeen++;
    }
    await next;
    if (await waitPresence(uid, true, const Duration(seconds: 10)) != null) {
      flapOnlineSeen++;
    }
  }
  await Future.delayed(const Duration(seconds: 2));
  final finalPresence = await readPresence(uid);
  results['S5_flaps'] = {
    'flaps': _flaps,
    'offline_seen': flapOfflineSeen,
    'online_seen': flapOnlineSeen,
    'registrations_during_flaps': c.count('registered') - regBefore,
    'register_errors': c.count('register_error'),
    'final_online': finalPresence?['online'],
    'accepted_connections_total': proxy.accepted,
    'handshake_host_rewrites': proxy.hostRewrites,
  };

  // --- S6: graceful while the link is down ----------------------------------
  log('S6 graceful while offline');
  proxy.accepting = false;
  proxy.resetAll();
  await c
      .waitFor('connected', where: (e) => e['value'] == false)
      .catchError((_) => <String, dynamic>{});
  c.send('graceful');
  final s6 = await c
      .waitFor('graceful_done', timeout: const Duration(seconds: 15))
      .then((e) => e['ms'], onError: (_) => 'timeout');
  c.process.kill(ProcessSignal.sigkill);
  final s6Presence = await readPresence(uid);
  results['S6_graceful_offline_link'] = {
    'graceful_done_ms': s6,
    'server_online': s6Presence?['online'],
  };
  proxy.accepting = true;

  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'dart': Platform.version,
      'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
      'results': results,
    }),
  );
  Directory(storage).deleteSync(recursive: true);
  exit(0);
}
