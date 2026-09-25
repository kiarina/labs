import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'platform/platform.dart';
import 'scenario.dart';

String _param(String key, String fallback) => envValue(key) ?? fallback;

ScenarioConfig _config() => ScenarioConfig(
  scenario: _param('scenario', 'loopback'),
  seconds: int.tryParse(_param('seconds', '12')) ?? 12,
  convertWidth: int.tryParse(_param('convert', '320')) ?? 320,
  deliver: _param('deliver', 'true') == 'true',
  startRecording: _param('startrecording', 'true') == 'true',
);

void main() => runApp(const TapsApp());

class TapsApp extends StatelessWidget {
  const TapsApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Media taps',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const RunPage(),
  );
}

/// Runs the configured scenario once on start (renderers attached, as a real
/// app would), prints `TAPS_RESULT {json}`, and exits when `exit=true`.
class RunPage extends StatefulWidget {
  const RunPage({super.key});

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  final _local = RTCVideoRenderer();
  final _remote = RTCVideoRenderer();
  String _status = 'starting';
  String? _result;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    await _local.initialize();
    await _remote.initialize();
    final config = _config();
    final report = await runScenario(
      config,
      onStreams: (local, remote) {
        _local.srcObject = local;
        _remote.srcObject = remote;
      },
      onStatus: (s) {
        if (mounted) setState(() => _status = s);
      },
    );
    report['renderer'] = {
      'local': '${_local.videoWidth}x${_local.videoHeight}',
      'remote': '${_remote.videoWidth}x${_remote.videoHeight}',
    };
    final json = jsonEncode(report);
    // ignore: avoid_print
    print('TAPS_RESULT $json');
    writeResult(json);
    if (mounted) {
      setState(() {
        _status = 'done';
        _result = const JsonEncoder.withIndent('  ').convert(report);
      });
    }
    if (_param('exit', 'false') == 'true') exitApp();
  }

  @override
  void dispose() {
    _local.dispose();
    _remote.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Media taps — $_status')),
    body: Column(
      children: [
        SizedBox(
          height: 180,
          child: Row(
            children: [
              Expanded(child: RTCVideoView(_local, mirror: true)),
              Expanded(child: RTCVideoView(_remote)),
            ],
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              _result ?? 'Running ${jsonEncode(_config().toJson())}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
      ],
    ),
  );
}
