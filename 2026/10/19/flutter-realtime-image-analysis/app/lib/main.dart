import 'dart:convert';

import 'package:flutter/material.dart';

import 'engine.dart';
import 'host.dart';
import 'parity.dart';
import 'replay.dart';

/// parity | replay | replay-fast (empty: wait for a button).
const autoMode = String.fromEnvironment('AUTO');
const autoExit = bool.fromEnvironment('AUTO_EXIT');

void main() => runApp(const SightLabApp());

class SightLabApp extends StatefulWidget {
  const SightLabApp({super.key});

  @override
  State<SightLabApp> createState() => _SightLabAppState();
}

class _SightLabAppState extends State<SightLabApp> {
  final _lines = <String>[];
  var _busy = false;

  void _log(String line) {
    // ignore: avoid_print
    print('SIGHT_LAB $line');
    setState(() {
      _lines.add(line);
      if (_lines.length > 200) _lines.removeAt(0);
    });
  }

  @override
  void initState() {
    super.initState();
    if (autoMode.isNotEmpty) WidgetsBinding.instance.addPostFrameCallback((_) => _run(autoMode));
  }

  Future<void> _run(String mode) async {
    if (_busy) return;
    setState(() => _busy = true);
    final report = <String, Object?>{
      'mode': mode,
      'run_id': const String.fromEnvironment('RUN_ID'),
      ...hostInfo(),
      'ort_threads': ortThreads,
    };
    try {
      final sw = Stopwatch()..start();
      final engine = await Engine.load(log: _log);
      report['models'] = engine.modelFiles;
      report['load_ms'] = {...engine.loadMs, 'total': sw.elapsedMilliseconds};
      final fx = await Fixtures.load();
      _log('models ready in ${sw.elapsedMilliseconds} ms');
      if (mode == 'parity') {
        report['parity'] = await runParity(engine, fx, _log);
      } else {
        report['replay'] = await runReplay(engine, fx, realtime: mode == 'replay', log: _log);
      }
      report['ok'] = true;
    } catch (e, st) {
      report['ok'] = false;
      report['error'] = '$e\n$st';
      _log('error: $e');
    }
    final json = const JsonEncoder.withIndent(' ').convert(report);
    // logcat cuts lines at ~1 KB: also print the report in numbered parts
    // (tools/join_report.py puts them back together)
    final line = jsonEncode(report);
    const size = 700;
    final parts = (line.length + size - 1) ~/ size;
    for (var i = 0; i < parts; i++) {
      final end = (i + 1) * size < line.length ? (i + 1) * size : line.length;
      // ignore: avoid_print
      print('SIGHT_LAB_REPORT ${i + 1}/$parts ${line.substring(i * size, end)}');
    }
    final path = await saveReport('report-$platformName-$mode.json', json);
    _log('report saved: ${path ?? 'page'}');
    setState(() => _busy = false);
    if (autoExit) exitApp();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('sight lab')),
          body: Column(children: [
            Wrap(spacing: 8, children: [
              for (final m in ['parity', 'replay', 'replay-fast'])
                ElevatedButton(onPressed: _busy ? null : () => _run(m), child: Text(m)),
            ]),
            Expanded(
              child: ListView(padding: const EdgeInsets.all(8), children: [for (final l in _lines) Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 12))]),
            ),
          ]),
        ),
      );
}
