import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'engine.dart';
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
      'platform': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'processors': Platform.numberOfProcessors,
      'dart': Platform.version.split(' ').first,
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
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/report-${Platform.operatingSystem}-$mode.json');
    await file.writeAsString(const JsonEncoder.withIndent(' ').convert(report));
    _log('report: ${file.path}');
    setState(() => _busy = false);
    if (autoExit) exit(0);
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
