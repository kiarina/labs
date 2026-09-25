import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:media_taps/media_taps.dart';

import 'idle/audio_probe.dart';
import 'idle/camera_probe.dart';
import 'live/live_session.dart';
import 'platform/platform.dart';

String _param(String key, String fallback) => envValue(key) ?? fallback;

void main() => runApp(const LiveApp());

class LiveApp extends StatelessWidget {
  const LiveApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'GPT-Live senses',
    theme: ThemeData(colorSchemeSeed: Colors.deepPurple, useMaterial3: true),
    home: const RunPage(),
  );
}

/// Runs idle (A) → conversation (B) → idle (A) once and reports timings.
class RunPage extends StatefulWidget {
  const RunPage({super.key});

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  final _remote = RTCVideoRenderer();
  final _clock = Stopwatch()..start();
  String _status = 'starting';
  String? _result;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _setStatus(String s) {
    // ignore: avoid_print
    print('LIVE_STATUS ${_clock.elapsedMilliseconds} $s');
    if (mounted) setState(() => _status = s);
  }

  int get _now => _clock.elapsedMilliseconds;

  /// Idle state A: `record` + `camera`. Returns stats and the time the first
  /// audio chunk / camera frame arrived (on the run clock).
  Future<Map<String, Object?>> _idle(String name, Duration length) async {
    _setStatus('$name: record + camera');
    final startAt = _now;
    final audio = AudioProbe();
    final camera = CameraProbe();
    int? firstAudioAt;
    int? firstFrameAt;
    final errors = <String>[];
    try {
      await Future.wait([
        audio.start().catchError((Object e) => errors.add('audio: $e')),
        camera.start().catchError((Object e) => errors.add('camera: $e')),
      ]);
      final until = _now + length.inMilliseconds;
      while (_now < until) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        if (firstAudioAt == null && audio.samples > 0) firstAudioAt = _now;
        if (firstFrameAt == null && camera.stats.frames > 0) {
          firstFrameAt = _now;
        }
      }
    } catch (e) {
      errors.add('$e');
    }
    final stopAt = _now;
    try {
      await audio.stop();
    } catch (_) {}
    try {
      await camera.stop();
    } catch (_) {}
    return {
      'startAt': startAt,
      'firstAudioAt': firstAudioAt,
      'firstFrameAt': firstFrameAt,
      'stopAt': stopAt,
      'stoppedAt': _now,
      'audio': audio.stats(),
      'camera': camera.toJson(),
      'errors': errors,
    };
  }

  Future<void> _run() async {
    await _remote.initialize();
    final relay = Uri.parse(_param('relay', 'http://127.0.0.1:8788/session'));
    final bSeconds = int.tryParse(_param('seconds', '30')) ?? 30;
    final report = <String, Object?>{
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      'config': {'relay': relay.toString(), 'conversationSeconds': bSeconds},
    };
    try {
      report['idleBefore'] = await _idle('A1', const Duration(seconds: 5));
      report['conversation'] = await _conversation(relay, bSeconds);
      // Optional pause after closing WebRTC before `record` / `camera` reopen
      // the devices (macOS: see the README).
      final settle = int.tryParse(_param('settle', '0')) ?? 0;
      report['settleMs'] = settle;
      if (settle > 0) {
        _setStatus('settle ${settle}ms');
        await Future<void>.delayed(Duration(milliseconds: settle));
      }
      report['idleAfter'] = await _idle('A2', const Duration(seconds: 4));
    } catch (e, st) {
      report['error'] = '$e';
      debugPrint('$st');
    }
    final json = jsonEncode(report);
    // ignore: avoid_print
    print('LIVE_RESULT $json');
    writeResult(json);
    if (mounted) {
      setState(() {
        _status = 'done';
        _result = const JsonEncoder.withIndent('  ').convert(report);
      });
    }
    if (_param('exit', 'false') == 'true') exitApp();
  }

  Future<Map<String, Object?>> _conversation(Uri relay, int seconds) async {
    _setStatus('B: connecting');
    final session = LiveSession(
      relay: relay,
      clock: _clock,
      stopAdm: _param('release', '') == 'stopadm',
    );
    final out = <String, Object?>{
      'startAt': _now,
      'release': _param('release', ''),
    };
    final tapStats = <String, Object?>{};
    try {
      await session.start();
      _remote.srcObject = session.remoteStream;
      final taps = await session.attachTaps();
      await session.started.future.timeout(const Duration(seconds: 15));
      _setStatus('B: session started');

      // The analysis result arrives as silent context; the instruction then
      // asks the model to use it. The transcript tells whether it did.
      session.send('session.thinking.append', {
        'delegation_id': null,
        'content': '（映像解析の結果）いまカメラの前には、赤いマグカップと青いノートが置かれている。',
      });
      final kick = _param('kick', 'both');
      if (kick == 'instructions' || kick == 'both') {
        session.send('session.instructions.append', {
          'delegation_id': null,
          'content':
              'いますぐ日本語で短く挨拶し、続けて、いまカメラの前に何が見えているかを一文で伝えてください。'
              'そのあとは黙って相手を待ってください。',
        });
      }
      if (kick == 'commentary' || kick == 'both') {
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        session.send('session.commentary.append', {
          'delegation_id': null,
          'content': 'こんにちは。接続テストです。いまカメラの前には、赤いマグカップと青いノートが見えています。',
        });
      }

      // Poll the taps: when did the first audio / frame arrive, and the
      // tapped mic level over time (should stay low while the model speaks,
      // because the tap is after echo cancellation).
      int? firstTapAudioAt;
      int? firstTapFrameAt;
      final levels = <List<num>>[];
      var frames = 0;
      var samples = 0;
      var squares = 0.0;
      var windowSamples = 0;
      var windowStart = _now;
      final until = _now + seconds * 1000;
      Map<String, Object?>? audioCounters;
      Map<String, Object?>? videoCounters;
      Map<String, Object?>? remoteCounters;
      final remoteLevels = <List<num>>[];
      var rSquares = 0.0;
      var rSamples = 0;
      while (_now < until) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        for (final snap in await MediaTaps.instance.poll()) {
          if (snap.id == taps['audio']) {
            audioCounters = snap.counters;
            final pcm = snap.pcm;
            if (pcm != null && pcm.isNotEmpty) {
              firstTapAudioAt ??= _now;
              samples += pcm.length;
              windowSamples += pcm.length;
              for (final v in pcm) {
                squares += v * v;
              }
            }
          } else if (snap.id == taps['remoteAudio']) {
            remoteCounters = snap.counters;
            final pcm = snap.pcm;
            if (pcm != null) {
              for (final v in pcm) {
                rSquares += v * v;
              }
              rSamples += pcm.length;
            }
          } else if (snap.id == taps['video']) {
            videoCounters = snap.counters;
            if (snap.frames.isNotEmpty) firstTapFrameAt ??= _now;
            frames += snap.frames.length;
          }
        }
        if (_now - windowStart >= 500) {
          final rms = windowSamples == 0
              ? 0.0
              : math.sqrt(squares / windowSamples) / 32768;
          levels.add([_now, double.parse(rms.toStringAsFixed(5))]);
          final rRms = rSamples == 0
              ? 0.0
              : math.sqrt(rSquares / rSamples) / 32768;
          remoteLevels.add([_now, double.parse(rRms.toStringAsFixed(5))]);
          rSquares = 0;
          rSamples = 0;
          squares = 0;
          windowSamples = 0;
          windowStart = _now;
        }
      }
      tapStats.addAll({
        'firstTapAudioAt': firstTapAudioAt,
        'firstTapFrameAt': firstTapFrameAt,
        'samples': samples,
        'framesToDart': frames,
        'audioCounters': audioCounters,
        'videoCounters': videoCounters,
        'micLevelTimeline': levels,
        'remoteCounters': remoteCounters,
        'remoteLevelTimeline': remoteLevels,
      });
    } catch (e) {
      out['error'] = '$e';
    } finally {
      _setStatus('B: closing');
      try {
        await session.close();
      } catch (e) {
        out['closeError'] = '$e';
      }
      _remote.srcObject = null;
    }
    final output = session.transcript('session.output_transcript.delta');
    final input = session.transcript('session.input_transcript.delta');
    out.addAll({
      'marks': session.marks,
      'taps': tapStats,
      'outputTranscript': output,
      'inputTranscript': input,
      'mentionsMug': output.contains('マグカップ'),
      'labEvents': [
        for (final e in session.events)
          if (e.type.startsWith('lab.') || e.type == 'error') e.json,
      ],
      'eventCounts': {
        for (final e in session.events)
          e.type: session.events.where((x) => x.type == e.type).length,
      },
      'contextAcks': [
        for (final e in session.events)
          if ((e.type).endsWith('.appended')) e.json,
      ],
      'errors': [
        for (final e in session.events)
          if (e.type == 'error') e.json,
      ],
      'closedEvent': [
        for (final e in session.events)
          if (e.type == 'session.closed') e.json,
      ],
      'outputTranscriptTimes': [
        for (final e in session.events)
          if (e.type == 'session.output_transcript.delta') e.atMs,
      ],
      'inputTranscriptTimes': [
        for (final e in session.events)
          if (e.type == 'session.input_transcript.delta') e.atMs,
      ],
    });
    return out;
  }

  @override
  void dispose() {
    _remote.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('GPT-Live senses — $_status')),
    body: Column(
      children: [
        // Web needs a renderer on the remote stream to play the model's voice.
        SizedBox(height: 1, width: 1, child: RTCVideoView(_remote)),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              _result ?? _status,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
      ],
    ),
  );
}
