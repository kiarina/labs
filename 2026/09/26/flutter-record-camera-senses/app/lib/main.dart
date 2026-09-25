import 'dart:async';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:camera/camera.dart' show ResolutionPreset;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:record/record.dart';

import 'audio_probe.dart';
import 'camera_probe.dart';
import 'platform/platform.dart';
import 'signal.dart';

String _param(String key, String fallback) => envValue(key) ?? fallback;

void main() => runApp(const SensesApp());

class SensesApp extends StatelessWidget {
  const SensesApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Senses',
    theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
    home: const RunPage(),
  );
}

/// One echo-test configuration.
final class EchoVariant {
  final String name;
  final bool echoCancel;
  final bool noiseSuppress;
  final bool autoGain;

  /// Android: capture with VOICE_COMMUNICATION in communication mode and play
  /// the test signal as voice communication, which is how Android pairs its
  /// echo canceller with a playback reference.
  final bool androidVoice;

  const EchoVariant(
    this.name, {
    this.echoCancel = false,
    this.noiseSuppress = false,
    this.autoGain = false,
    this.androidVoice = false,
  });
}

List<EchoVariant> _variants() => [
  const EchoVariant('raw'),
  const EchoVariant('ec', echoCancel: true),
  const EchoVariant(
    'ec-ns-agc',
    echoCancel: true,
    noiseSuppress: true,
    autoGain: true,
  ),
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
    const EchoVariant(
      'voice-ec-ns-agc',
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
      androidVoice: true,
    ),
];

class RunPage extends StatefulWidget {
  const RunPage({super.key});

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  CameraProbe? _camera;
  String _status = 'starting';
  String? _result;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  void _setStatus(String s) {
    // ignore: avoid_print
    print('SENSES_STATUS $s');
    if (mounted) setState(() => _status = s);
  }

  Future<void> _run() async {
    final scenario = _param('scenario', 'all');
    final seconds = int.tryParse(_param('seconds', '20')) ?? 20;
    final interval = Duration(
      milliseconds: int.tryParse(_param('interval', '200')) ?? 200,
    );
    final preset = ResolutionPreset.values.byName(_param('preset', 'high'));
    final echoOnWeb = _param('echo', '') == 'force';
    final report = <String, Object?>{
      'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
      'config': {
        'scenario': scenario,
        'seconds': seconds,
        'intervalMs': interval.inMilliseconds,
        'preset': preset.name,
      },
    };
    final errors = <String>[];

    // Camera stays on for the whole run (the body's eyes are always open).
    final camera = _camera = CameraProbe(preset: preset, interval: interval);
    try {
      _setStatus('camera');
      await camera.start();
      if (mounted) setState(() {});
    } catch (e) {
      errors.add('camera: $e');
    }

    if (scenario == 'all' || scenario == 'senses') {
      _setStatus('senses ${seconds}s');
      final audio = AudioProbe();
      try {
        await audio.start();
        await Future<void>.delayed(Duration(seconds: seconds));
        report['sensesAudio'] = {
          ...audio.stats(),
          'rmsDbfs': db(rms(audio.samplesFrom(0))),
        };
      } catch (e) {
        errors.add('senses audio: $e');
      } finally {
        try {
          await audio.stop();
        } catch (_) {}
      }
      report['sensesCamera'] = camera.toJson();
    }

    if ((scenario == 'all' || scenario == 'echo') && (!kIsWeb || echoOnWeb)) {
      report['echo'] = await _echoTests(errors);
    } else if (scenario == 'all' || scenario == 'echo') {
      report['echo'] = 'skipped on web (headless fake mic cannot hear the speaker; pass echo=force)';
    }

    report['camera'] = camera.toJson();
    try {
      await camera.stop();
    } catch (e) {
      errors.add('camera stop: $e');
    }
    report['errors'] = errors;

    final json = jsonEncode(report);
    // ignore: avoid_print
    print('SENSES_RESULT $json');
    writeResult(json);
    if (mounted) {
      setState(() {
        _status = 'done';
        _result = const JsonEncoder.withIndent('  ').convert(report);
      });
    }
    if (_param('exit', 'false') == 'true') exitApp();
  }

  Future<List<Map<String, Object?>>> _echoTests(List<String> errors) async {
    const rate = AudioProbe.sampleRate;
    final reference = echoTestSignal(sampleRate: rate);
    final wav = wavBytes(
      reference,
      sampleRate: rate,
      tail: const Duration(seconds: 1),
    );
    final path = await writeTempFile('echo_test.wav', wav);
    final Source source = path != null
        ? DeviceFileSource(path)
        : UrlSource('data:audio/wav;base64,${base64Encode(wav)}');
    final results = <Map<String, Object?>>[];

    for (final v in _variants()) {
      _setStatus('echo ${v.name}');
      final player = AudioPlayer();
      final audio = AudioProbe(
        echoCancel: v.echoCancel,
        noiseSuppress: v.noiseSuppress,
        autoGain: v.autoGain,
        androidSource: v.androidVoice
            ? AndroidAudioSource.voiceCommunication
            : AndroidAudioSource.defaultSource,
      );
      final r = <String, Object?>{
        'variant': v.name,
        'playerContext': _param('playerctx', 'set'),
      };
      try {
        // playerctx=none leaves the audio session to `record` (iOS: tests
        // whether audioplayers' session change disturbs the recorder).
        if (_param('playerctx', 'set') != 'none') {
          await player.setAudioContext(
            AudioContext(
              iOS: AudioContextIOS(
                category: AVAudioSessionCategory.playAndRecord,
                options: const {
                  AVAudioSessionOptions.defaultToSpeaker,
                  AVAudioSessionOptions.mixWithOthers,
                },
              ),
              android: AudioContextAndroid(
                isSpeakerphoneOn: v.androidVoice,
                audioMode: v.androidVoice
                    ? AndroidAudioMode.inCommunication
                    : AndroidAudioMode.normal,
                contentType: v.androidVoice
                    ? AndroidContentType.speech
                    : AndroidContentType.music,
                usageType: v.androidVoice
                    ? AndroidUsageType.voiceCommunication
                    : AndroidUsageType.media,
                audioFocus: AndroidAudioFocus.none,
              ),
            ),
          );
        }
        await player.setVolume(1.0);
        await audio.start();
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        final baseStart = audio.samples;
        await Future<void>.delayed(const Duration(seconds: 2));
        final baseEnd = audio.samples;
        final done = Completer<void>();
        final sub = player.onPlayerComplete.listen((_) {
          if (!done.isCompleted) done.complete();
        });
        final playStart = audio.samples;
        await player.play(source);
        await Future.any([
          done.future,
          Future<void>.delayed(const Duration(seconds: 8)),
        ]);
        await sub.cancel();
        r['playbackCompleted'] = done.isCompleted;
        final playEnd = audio.samples;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final base = rms(audio.samplesFrom(baseStart, baseEnd));
        final recorded = audio.samplesFrom(playStart, playEnd);
        // The signal occupies the first 4 s after playback starts (plus
        // output latency); measure over that part only.
        final play = rms(recorded, 0, 4 * rate + rate ~/ 2);
        final corr = echoCorrelation(reference, recorded, sampleRate: rate);
        r.addAll({
          'audio': audio.stats(),
          'baselineDbfs': db(base),
          'playbackDbfs': db(play),
          'leakDb': (db(play) != null && db(base) != null)
              ? db(play)! - db(base)!
              : null,
          'samplesCaptured': recorded.length,
          'nonZeroSamples': recorded.where((s) => s != 0).length,
          'correlation': corr.peak,
          'lagMs': corr.lagMs,
          'recordedMs': recorded.length * 1000 ~/ rate,
        });
      } catch (e) {
        r['error'] = '$e';
        errors.add('echo ${v.name}: $e');
      } finally {
        try {
          await audio.stop();
        } catch (_) {}
        await player.dispose();
      }
      results.add(r);
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return results;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('Senses — $_status')),
    body: Column(
      children: [
        SizedBox(height: 200, child: _camera?.preview() ?? const SizedBox()),
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
