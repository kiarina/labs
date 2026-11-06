/// The peer under test: a Flutter-free Dart process (`--impl webrtc_dart` or
/// `--impl libdatachannel`) that links
/// to an echo peer through bin/signal.dart, the way the app's mesh does
/// (trickle ICE, one ordered reliable data channel `nerve`, J/C framing),
/// then runs the checks and writes a JSON result.
///
///   dart run bin/probe.dart --signal ws://127.0.0.1:8899 --role offer \
///     --end close --out ../results/x.json [--stun stun:stun.cloudflare.com:3478]
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:dart_cli_webrtc_probe/frames.dart';
import 'package:dart_cli_webrtc_probe/impl_ldc.dart';
import 'package:dart_cli_webrtc_probe/impl_webrtc_dart.dart';
import 'package:dart_cli_webrtc_probe/rtc.dart';
import 'package:logging/logging.dart';

final _sw = Stopwatch()..start();
double get _ms => _sw.elapsedMicroseconds / 1000;
final _events = <Map<String, Object?>>[];
void _event(String what, [Object? detail]) {
  final e = {
    't_ms': double.parse(_ms.toStringAsFixed(1)),
    'what': what,
    'detail': ?detail,
  };
  _events.add(e);
  stdout.writeln('[${e['t_ms']}] $what${detail == null ? '' : ' $detail'}');
}

Future<void> main(List<String> argv) async {
  final args = _parse(argv);
  if (Platform.environment['RTC_LOG'] != null) {
    Logger.root.level = Level.ALL;
    Logger.root.onRecord.listen(
      (r) => stderr.writeln('${r.loggerName} ${r.level.name}: ${r.message}'),
    );
  }
  final role = args['role'] ?? 'offer';
  final end = args['end'] ?? 'close';
  final out = args['out'];
  final stun = args['stun'];
  final result = <String, Object?>{
    'label': args['label'] ?? '',
    'role': role,
    'end': end,
    'stun': stun,
    'dart': Platform.version,
    'os': '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    'executable': Platform.resolvedExecutable
        .split(Platform.pathSeparator)
        .last,
    'aot': const bool.fromEnvironment('dart.vm.product'),
  };
  final checks = <String, Object?>{};
  result['checks'] = checks;
  try {
    // An error the library raises outside our awaits (webrtc_dart's DTLS
    // failures) ends the run the same way.
    final failed = Completer<void>();
    unawaited(
      runZonedGuarded(
        () =>
            _run(
              args['signal'] ?? 'ws://127.0.0.1:8899',
              role,
              end,
              stun,
              checks,
              result,
              args['impl'] ?? 'webrtc_dart',
            ).then((_) {
              if (!failed.isCompleted) failed.complete();
            }),
        (e, s) {
          if (!failed.isCompleted) failed.completeError(e, s);
        },
      ),
    );
    await failed.future;
    result['ok'] = checks.values.every((c) => c is! Map || c['ok'] != false);
  } catch (e, s) {
    _event('error', '$e');
    result['ok'] = false;
    result['error'] = '$e\n$s';
  }
  result['events'] = _events;
  if (out != null) {
    File(out)
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(const JsonEncoder.withIndent('  ').convert(result));
  }
  stdout.writeln('ok=${result['ok']}');
  exit(result['ok'] == true ? 0 : 1);
}

Map<String, String> _parse(List<String> a) => {
  for (var i = 0; i + 1 < a.length; i += 2)
    a[i].replaceFirst('--', ''): a[i + 1],
};

Future<void> _run(
  String signalUrl,
  String role,
  String end,
  String? stun,
  Map<String, Object?> checks,
  Map<String, Object?> result,
  String impl,
) async {
  final ws = await WebSocket.connect('$signalUrl/ws');
  _event('signal connected');
  final signals = StreamIterator(
    ws.cast<String>().map(
      (s) => (jsonDecode(s) as Map).cast<String, dynamic>(),
    ),
  );
  while (await signals.moveNext().timeout(const Duration(seconds: 60))) {
    if (signals.current['k'] == 'peer') break;
  }
  final tPeer = _ms;
  _event('peer present');

  final servers = [?stun];
  final Rtc rtc = impl == 'libdatachannel'
      ? LdcRtc(iceServers: servers)
      : WebrtcDartRtc(iceServers: servers);
  result['impl'] = rtc.info;
  // webrtc_dart 0.25.3 only sends ASCII strings correctly (frames.dart).
  final ascii = impl == 'webrtc_dart';
  final states = <String>[];
  final gone = Completer<String>();
  var watchingGone = false;
  rtc.states.listen((s) {
    states.add(s);
    _event('pc', s);
    if (watchingGone &&
        const {'disconnected', 'failed', 'closed'}.contains(s) &&
        !gone.isCompleted) {
      gone.complete('pc $s');
    }
  });
  final localCandidates = <String>[];
  rtc.signals.listen((m) {
    if (m['k'] == 'cand') {
      localCandidates.add(_candidateKind(m['candidate'] as String));
      _event('local candidate', localCandidates.last);
    } else {
      _event('local ${m['k']}');
    }
    ws.add(jsonEncode(m));
  });
  final remoteCandidates = <String>[];
  // Signals keep arriving (candidates) while the checks run.
  unawaited(() async {
    while (await signals.moveNext()) {
      final m = signals.current;
      if (m['k'] == 'cand') {
        remoteCandidates.add(_candidateKind(m['candidate'] as String? ?? ''));
        _event('remote candidate', remoteCandidates.last);
      } else {
        _event('remote ${m['k']}');
      }
      await rtc.onSignal(m);
    }
  }());

  final dc = await rtc
      .start(offer: role == 'offer')
      .timeout(const Duration(seconds: 30));
  final tOpen = _ms;
  _event('channel open', dc.label);
  checks['open'] = {
    'ok': true,
    'ms_from_peer_present': double.parse((tOpen - tPeer).toStringAsFixed(1)),
    'label': dc.label,
  };

  // Echoed frames back into messages.
  final reader = FrameReader();
  final incoming = StreamController<Map<String, dynamic>>();
  dc.messages.listen((m) {
    final msg = reader.add(m);
    if (msg != null) incoming.add(msg);
  });
  unawaited(
    dc.closed.then((_) {
      _event('channel closed');
      if (watchingGone && !gone.isCompleted) gone.complete('channel closed');
    }),
  );
  final replies = StreamIterator(incoming.stream);
  var seq = 0;
  Future<void> send(Map<String, dynamic> m) async {
    for (final f in encodeFrames(m, ++seq, asciiOnly: ascii)) {
      await dc.send(f);
    }
  }

  Future<Map<String, dynamic>> next() async {
    if (!await replies.moveNext().timeout(const Duration(seconds: 60))) {
      throw StateError('channel ended');
    }
    return replies.current;
  }

  // 1. Round trips of small messages, one at a time.
  final rtts = <double>[];
  for (var i = 0; i < 200; i++) {
    final t = _ms;
    await send({'i': i, 'kind': 'rtt'});
    final r = await next();
    if (r['i'] != i) throw StateError('rtt out of order: $r');
    rtts.add(_ms - t);
  }
  rtts.sort();
  checks['rtt_small'] = {
    'ok': true,
    'n': rtts.length,
    'median_ms': _r(rtts[rtts.length ~/ 2]),
    'p95_ms': _r(rtts[(rtts.length * 0.95).floor()]),
    'max_ms': _r(rtts.last),
  };

  // 2. Short texts by script, then messages of growing size, mixed scripts,
  // compared after the echo.
  final scripts = <Map<String, Object?>>[];
  for (final (name, text) in [
    ('ascii', 'spirit body console ' * 5),
    ('quote_backslash_newline', 'a"b\\c\nd'),
    ('japanese', '精霊の庭で暮らす'),
    ('emoji', '🌱👩‍💻'),
  ]) {
    await send({'kind': 'script', 'text': text});
    Map<String, dynamic>? r;
    try {
      r = await next().timeout(const Duration(seconds: 5));
    } catch (_) {}
    scripts.add({
      'script': name,
      'ok': r?['text'] == text,
      'echoed': r != null,
    });
    if (r == null) break; // A lost message would shift every later echo.
  }
  checks['scripts'] = {
    'ok': scripts.every((s) => s['ok'] == true),
    'cases': scripts,
  };
  if (scripts.any((s) => s['echoed'] != true))
    throw StateError('a short message was not echoed: $scripts');

  // Messages of growing size, mixed scripts, compared after the echo.
  final sizes = <Map<String, Object?>>[];
  for (final n in [100, 15000, 16001, 65536, 262144, 1048576]) {
    final text = _mixed(n);
    final t = _ms;
    await send({'kind': 'size', 'n': n, 'text': text});
    final r = await next();
    final frames = encodeFrames(
      {'kind': 'size', 'n': n, 'text': text},
      0,
      asciiOnly: ascii,
    );
    // A frame that ends in a high surrogate: the pair is split across two
    // frames, and each half alone is not valid UTF-16 to encode as UTF-8.
    final split = frames.take(frames.length - 1).where((f) {
      final u = f.codeUnitAt(f.length - 1);
      return u >= 0xD800 && u <= 0xDBFF;
    }).length;
    sizes.add({
      'chars': n,
      'frames': frames.length,
      'boundaries_inside_pair': split,
      'equal': r['text'] == text,
      'ms': _r(_ms - t),
    });
  }
  checks['sizes'] = {
    // Judged on the cases the framing itself does not break.
    'ok': sizes
        .where((s) => s['boundaries_inside_pair'] == 0)
        .every((s) => s['equal'] == true),
    'split_cases_equal': [
      for (final s in sizes)
        if (s['boundaries_inside_pair'] != 0) s['equal'],
    ],
    'cases': sizes,
  };

  // 3. A burst sent without waiting, checked for count and order.
  {
    const n = 2000;
    final body = 'x' * 1000;
    final t = _ms;
    for (var i = 0; i < n; i++) {
      await send({'i': i, 'kind': 'burst', 'b': body});
    }
    final tSent = _ms;
    var inOrder = true;
    for (var i = 0; i < n; i++) {
      final r = await next();
      if (r['i'] != i) inOrder = false;
    }
    final total = _ms - t;
    checks['burst'] = {
      'ok': inOrder,
      'n': n,
      'bytes_each_way':
          n * (jsonEncode({'i': 0, 'kind': 'burst', 'b': body}).length + 1),
      'send_ms': _r(tSent - t),
      'total_ms': _r(total),
      'mb_per_s_each_way': _r(n * 1030 / 1e6 / (total / 1000)),
    };
  }

  // 4. The other end goes away: closed politely, or killed.
  {
    final t = _ms;
    watchingGone = true;
    await send({'op': end});
    String? how;
    try {
      how = await gone.future.timeout(const Duration(seconds: 90));
    } on TimeoutException {
      how = null;
    }
    checks['remote_gone'] = {
      'ok': how != null,
      'end': end,
      'first_sign': how,
      'ms': how == null ? null : _r(_ms - t),
    };
    // Keep watching a little for the later states (failed after disconnected).
    await Future<void>.delayed(Duration(seconds: end == 'kill' ? 0 : 2));
  }

  result['pc_states'] = states;
  result['local_candidates'] = localCandidates;
  result['remote_candidates'] = remoteCandidates;
  await rtc.close();
  await ws.close();
}

/// `host 192.168.1.2` style summary of an ICE candidate line.
String _candidateKind(String c) {
  final f = c.replaceFirst(RegExp(r'^a?=?candidate:'), '').split(' ');
  final typ = f.indexOf('typ');
  return f.length > 5 && typ > 0
      ? '${f[typ + 1]} ${f[2].toLowerCase()} ${f[4]}'
      : c;
}

double _r(double v) => double.parse(v.toStringAsFixed(2));

/// [n] UTF-16 units of ASCII, Japanese and emoji (whole pairs only).
String _mixed(int n) {
  const pieces = [
    'spirit ',
    '精霊の庭で',
    '🌱',
    'body',
    '"quote"\\',
    '\n',
    'ｶﾅ',
    '👩‍💻',
  ];
  final rnd = Random(n);
  final b = StringBuffer();
  while (b.length < n) {
    b.write(pieces[rnd.nextInt(pieces.length)]);
  }
  var s = b.toString();
  while (s.length > n) {
    s = s.substring(0, s.length - 1);
    // Do not leave half a pair at the end.
    final last = s.codeUnitAt(s.length - 1);
    if (last >= 0xD800 && last <= 0xDBFF) s = s.substring(0, s.length - 1);
  }
  return s;
}
