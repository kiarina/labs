import 'dart:async';
import 'dart:convert';
import 'dart:io' show exit, stdout;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pcm_asr/pcm_asr.dart';

/// `--dart-define=PCM_ASR_AUTOTEST=1`: run the fixture on start, print one
/// JSON line per step prefixed with `PCM_ASR `, and (on desktop) exit.
const autotest = String.fromEnvironment('PCM_ASR_AUTOTEST') == '1';
const locale = String.fromEnvironment('PCM_ASR_LOCALE', defaultValue: 'ja-JP');

/// Android lab knobs: write pace (1.0 = real time) and silent tail in ms.
const androidPace = String.fromEnvironment('PCM_ASR_ANDROID_PACE');
const androidTailMs = String.fromEnvironment('PCM_ASR_ANDROID_TAIL_MS');

void main() => runApp(const MaterialApp(home: FixturePage()));

class FixturePage extends StatefulWidget {
  const FixturePage({super.key});

  @override
  State<FixturePage> createState() => _FixturePageState();
}

class _FixturePageState extends State<FixturePage> {
  final asr = const PcmAsr();
  final lines = <String>[];
  bool running = false;

  @override
  void initState() {
    super.initState();
    if (autotest) scheduleMicrotask(run);
  }

  void log(String kind, Map<String, Object?> data) {
    final line = jsonEncode({'kind': kind, ...data});
    if (kIsWeb || defaultTargetPlatform == TargetPlatform.android) {
      // Browser console / logcat.
      // ignore: avoid_print
      print('PCM_ASR $line');
    } else {
      stdout.writeln('PCM_ASR $line');
    }
    setState(() => lines.add(line));
  }

  Future<void> run() async {
    if (running) return;
    setState(() {
      running = true;
      lines.clear();
    });
    var ok = false;
    String? unsupportedReason;
    try {
      log('platform', {'os': kIsWeb ? 'web' : defaultTargetPlatform.name, 'locale': locale});
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android && (androidPace.isNotEmpty || androidTailMs.isNotEmpty)) {
        await const MethodChannel('pcm_asr').invokeMethod('configure', {
          'pace': ?double.tryParse(androidPace),
          'tail_ms': ?int.tryParse(androidTailMs),
        });
        log('configure', {'pace': androidPace, 'tail_ms': androidTailMs});
      }
      final support = await asr.support(locale: locale);
      log('support', support.toJson());
      if (!support.supported) {
        unsupportedReason = support.reason ?? 'unsupported';
        return;
      }
      final prepareStart = DateTime.now();
      await asr.prepare(locale: locale);
      log('prepare', {'ms': DateTime.now().difference(prepareStart).inMilliseconds, 'model_state_before': support.modelState.name});

      final manifest = jsonDecode(await rootBundle.loadString('assets/segments/segments.json')) as List;
      final segments = <(Map<String, Object?>, Uint8List)>[];
      for (final raw in manifest) {
        final row = (raw as Map).cast<String, Object?>();
        final bytes = await rootBundle.load('assets/segments/${row['file']}');
        segments.add((row, bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes)));
      }
      // Three passes as in the earlier lab: forward, forward, reversed.
      for (var trial = 0; trial < 3; trial++) {
        final order = trial == 2 ? segments.reversed.toList() : segments;
        for (final (row, pcm) in order) {
          final id = '${row['id']}#$trial';
          final sent = DateTime.now();
          try {
            final result = await asr.transcribe(TranscribeRequest(
              id: id,
              locale: locale,
              audio: PcmSegment(pcm16le: pcm, sampleRate: row['sample_rate'] as int, channels: row['channels'] as int),
            ));
            log('result', {
              ...result.toJson(),
              'trial': trial,
              'segment_id': row['id'],
              'speaker_id': row['speaker_id'],
              'round_trip_ms': DateTime.now().difference(sent).inMilliseconds,
              'id_matches': result.id == id,
            });
          } on PcmAsrException catch (e) {
            log('error', {'id': id, 'trial': trial, 'code': e.code.name, 'message': e.message});
          }
        }
      }
      // Error paths the contract promises.
      try {
        await asr.transcribe(TranscribeRequest(
          id: 'bad-locale',
          locale: 'xx-XX',
          audio: PcmSegment(pcm16le: segments.first.$2, sampleRate: 16000),
        ));
        log('error_check', {'case': 'unsupported_locale', 'ok': false});
      } on PcmAsrException catch (e) {
        log('error_check', {'case': 'unsupported_locale', 'ok': e.code == PcmAsrErrorCode.unsupportedLocale, 'code': e.code.name});
      }
      final cancelId = 'cancel-me';
      final pending = asr.transcribe(TranscribeRequest(
        id: cancelId,
        locale: locale,
        audio: PcmSegment(pcm16le: segments.first.$2, sampleRate: 16000),
      ));
      await asr.cancel(cancelId);
      try {
        final r = await pending;
        log('error_check', {'case': 'cancel', 'ok': true, 'note': 'finished before cancel', 'text': r.text});
      } on PcmAsrException catch (e) {
        log('error_check', {'case': 'cancel', 'ok': e.code == PcmAsrErrorCode.cancelled, 'code': e.code.name});
      }
      // Silence must give empty text, not an error.
      try {
        final r = await asr.transcribe(TranscribeRequest(
          id: 'silence',
          locale: locale,
          audio: PcmSegment(pcm16le: Uint8List(16000 * 2), sampleRate: 16000),
        ));
        log('error_check', {'case': 'silence', 'ok': true, 'text': r.text, 'elapsed_ms': r.elapsed.inMilliseconds});
      } on PcmAsrException catch (e) {
        log('error_check', {'case': 'silence', 'ok': false, 'code': e.code.name, 'message': e.message});
      }
      await asr.dispose();
      ok = true;
    } catch (e, st) {
      log('fatal', {'error': e.toString(), 'stack': st.toString()});
    } finally {
      log('done', {'ok': ok, 'reason': ?unsupportedReason});
      if (mounted) setState(() => running = false);
      if (autotest && !kIsWeb && (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows)) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        exit(ok ? 0 : 1);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('pcm_asr fixture')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton(onPressed: running ? null : run, child: Text(running ? 'running…' : 'Run fixture ($locale)')),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: lines.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
                child: SelectableText(lines[i], style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
