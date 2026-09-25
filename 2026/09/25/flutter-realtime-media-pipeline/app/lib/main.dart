import 'package:flutter/material.dart';

import 'app/dependency_container.dart';
import 'app/env.dart';
import 'infrastructure/local/local_media_source.dart';
import 'presentation/home_page.dart';
import 'presentation/publisher_page.dart';
import 'presentation/session_page.dart';

// Scripted measurement runs, e.g.
//   flutter run -d macos --dart-define=AUTORUN=loopback --dart-define=AUTORUN_SECONDS=15
// The same keys also work as web query parameters (`?autorun=loopback`) and
// as native environment variables (`REALTIME_AUTORUN=loopback`), so one
// build serves every mode.
const _autorunDefine = String.fromEnvironment('AUTORUN');
const _autorunSecondsDefine = int.fromEnvironment(
  'AUTORUN_SECONDS',
  defaultValue: 15,
);
const _autorunExitDefine = bool.fromEnvironment('AUTORUN_EXIT');
final _autorunExit = _param('exit', '$_autorunExitDefine') == 'true';
const _probeDefine = String.fromEnvironment('PROBE', defaultValue: 'loopback');
const _signalingDefine = String.fromEnvironment(
  'SIGNALING',
  defaultValue: 'ws://127.0.0.1:8787',
);
const _roomDefine = String.fromEnvironment('ROOM', defaultValue: 'lab');

String _param(String key, String fallback) => envValue(key) ?? fallback;

final _autorun = _param('autorun', _autorunDefine);
final _autorunSeconds =
    int.tryParse(_param('seconds', '')) ?? _autorunSecondsDefine;
final _probe = _param('probe', _probeDefine);
final _signaling = _param('signaling', _signalingDefine);
final _room = _param('room', _roomDefine);
// Resolution experiment knobs (see ProbeTuning).
final _degradation = _param('degradation', '');
final _startBitrate = int.tryParse(_param('startbitrate', ''));
final _cpuOveruse = switch (_param('cpuoveruse', '')) {
  'true' => true,
  'false' => false,
  _ => null,
};

void main() => runApp(const RealtimePipelineApp());

class RealtimePipelineApp extends StatelessWidget {
  const RealtimePipelineApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Realtime Pipeline Test',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: _autorun.isEmpty ? const HomePage() : _autorunPage(),
    );
  }

  Widget _autorunPage() {
    final options = SessionOptions(
      signalingUrl: _signaling,
      room: _room,
      probe: LocalStatsProbe.values.byName(_probe),
      tuning: ProbeTuning(
        degradation: _degradation.isEmpty ? null : _degradation,
        startBitrateKbps: _startBitrate,
        cpuOveruseDetection: _cpuOveruse,
      ),
    );
    final spec = AutorunSpec(
      duration: Duration(seconds: _autorunSeconds),
      exitWhenDone: _autorunExit,
    );
    if (_autorun == 'publisher') {
      return PublisherPage(options: options, autorun: spec);
    }
    final mode = SessionMode.byKey(_autorun);
    if (mode == null) {
      return Scaffold(body: Center(child: Text('Unknown AUTORUN: $_autorun')));
    }
    return SessionPage(mode: mode, options: options, autorun: spec);
  }
}
