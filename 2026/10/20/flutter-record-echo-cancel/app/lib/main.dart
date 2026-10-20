import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'platform/platform.dart';
import 'recorder.dart';
import 'signal.dart';

/// Timeline of one variant's slot, in ms from the slot start. The device
/// under test (DUT) plays the far-end speech; another device (the helper)
/// plays the near-end speech, standing in for a person in the room.
abstract final class Slot {
  static const silenceFrom = 1500;
  static const silenceTo = 3500;
  static const farAt = 3500; // DUT plays far.wav (far-only)
  static const nearAt = 10500; // helper plays near.wav (near-only)
  static const dtAt = 17500; // both (double-talk)
  static const stopAt = 24500;
  static const signalMs = 6000;
}

void main() => runApp(const MaterialApp(home: EchoPage()));

class EchoPage extends StatefulWidget {
  const EchoPage({super.key});

  @override
  State<EchoPage> createState() => _EchoPageState();
}

class _EchoPageState extends State<EchoPage> {
  String _status = 'idle';
  String? _result;

  @override
  void initState() {
    super.initState();
    final raw = configJson();
    if (raw != null) {
      final config = jsonDecode(raw) as Map<String, Object?>;
      unawaited(config['role'] == 'helper' ? _helper(config) : _dut(config));
    }
  }

  void _set(String s) {
    if (mounted) setState(() => _status = s);
  }

  static Future<void> _until(int epochMs) async {
    final wait = epochMs - DateTime.now().millisecondsSinceEpoch;
    if (wait > 0) await Future<void>.delayed(Duration(milliseconds: wait));
  }

  /// Plays near.wav at nearAt and dtAt of each slot.
  Future<void> _helper(Map<String, Object?> config) async {
    final start = config['startEpochMs'] as int;
    final period = config['periodMs'] as int;
    final count = config['slots'] as int;
    final player = AudioPlayer();
    await player.setReleaseMode(ReleaseMode.stop);
    for (var i = 0; i < count; i++) {
      for (final at in [Slot.nearAt, Slot.dtAt]) {
        await _until(start + i * period + at);
        _set('helper slot $i at $at');
        await player.play(AssetSource('near.wav'), volume: 1.0);
      }
    }
    await Future<void>.delayed(const Duration(seconds: 7));
    _set('helper done');
    writeResult(jsonEncode({'role': 'helper', 'slots': count}));
    if (config['exit'] == true) exitApp();
  }

  Future<void> _dut(Map<String, Object?> config) async {
    final start = config['startEpochMs'] as int;
    final period = config['periodMs'] as int;
    final names = (config['variants'] as List).cast<String>();
    final far = wavSamples(
      (await rootBundle.load('assets/far.wav')).buffer.asUint8List(),
    );
    final near = wavSamples(
      (await rootBundle.load('assets/near.wav')).buffer.asUint8List(),
    );
    final farEnv = envelope(far, Mic.sampleRate);
    final nearEnv = envelope(near, Mic.sampleRate);
    final report = <String, Object?>{
      'platform': platformName(),
      'label': config['label'],
      'startEpochMs': start,
      'periodMs': period,
      'referenceCrossCorrelation': envelopeCorrelation(
        farEnv,
        nearEnv,
        minLagMs: -2500,
        maxLagMs: 2500,
      ).peak,
      'results': <Object?>[],
    };
    // The first startStream after launch can take seconds (11 s once on
    // macOS); open and close the microphone once so slot 0 starts on time.
    _set('warming up the microphone');
    final warm = Mic(Variant.byName('raw'));
    await warm.start();
    await Future<void>.delayed(const Duration(seconds: 2));
    await warm.stop();
    for (var i = 0; i < names.length; i++) {
      final v = Variant.byName(names[i]);
      final slot = start + i * period;
      _set('${v.name}: waiting');
      await _until(slot);
      (report['results'] as List).add(await _runSlot(v, slot, farEnv, nearEnv));
    }
    final json = jsonEncode(report);
    writeResult(json);
    if (mounted) {
      setState(() {
        _status = 'done';
        _result = const JsonEncoder.withIndent('  ').convert(report);
      });
    }
    if (config['exit'] == true) exitApp();
  }

  Future<Map<String, Object?>> _runSlot(
    Variant v,
    int slot,
    Float64List farEnv,
    Float64List nearEnv,
  ) async {
    final r = <String, Object?>{'variant': v.toJson()};
    final mic = Mic(v);
    final player = AudioPlayer();
    final playedAt = <int>[];
    try {
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
      await player.setReleaseMode(ReleaseMode.stop);
      _set('${v.name}: recording');
      await mic.start();
      for (final at in [Slot.farAt, Slot.dtAt]) {
        await _until(slot + at);
        playedAt.add(DateTime.now().millisecondsSinceEpoch - slot);
        await player.play(AssetSource('far.wav'), volume: 1.0);
      }
      await _until(slot + Slot.stopAt);
    } catch (e) {
      r['error'] = '$e';
    }
    final pcm = await mic.stop();
    await player.dispose();
    r['farPlayCalledAtMs'] = playedAt;
    r['chunks'] = mic.chunks;
    r['samples'] = pcm.length;
    r['maxGapMs'] = mic.maxGapMs;
    r['nonZeroSamples'] = pcm.where((s) => s != 0).length;
    final first = mic.firstSampleEpochMs;
    if (first == null || pcm.isEmpty) return r;
    r['firstSampleAtMs'] = first - slot;
    final rec = envelope(pcm, Mic.sampleRate);
    // Index (ms) in the recording of slot time t.
    int at(int t) => t - (first - slot);

    r['silenceDbfs'] = db(
      rms(pcm, at(Slot.silenceFrom) * 16, at(Slot.silenceTo) * 16),
    );
    // A phase: correlation with the reference near its scheduled time, and the
    // recorded level over the reference's span at the best lag. The near
    // speech comes from another device whose clock may be off by up to ~2 s.
    Map<String, Object?> phase(Float64List ref, int t, int lo, int hi) {
      final c = envelopeCorrelation(
        ref,
        rec,
        minLagMs: at(t) + lo,
        maxLagMs: at(t) + hi,
      );
      final s = c.lagMs;
      return {
        'correlation': c.peak,
        'offsetMs': s - at(t),
        'dbfs': db(rms(pcm, s * 16, (s + Slot.signalMs) * 16)),
      };
    }

    r['far'] = phase(farEnv, Slot.farAt, -200, 1000);
    r['near'] = phase(nearEnv, Slot.nearAt, -2500, 2500);
    r['doubleTalk'] = {
      'far': phase(farEnv, Slot.dtAt, -200, 1000),
      'near': phase(nearEnv, Slot.dtAt, -2500, 2500),
    };
    await saveRecording('${v.name}.wav', _wav(pcm));
    return r;
  }

  static Uint8List _wav(Int16List pcm) {
    final data = ByteData(44 + pcm.length * 2);
    void ascii(int o, String s) {
      for (var i = 0; i < s.length; i++) {
        data.setUint8(o + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    data.setUint32(4, 36 + pcm.length * 2, Endian.little);
    ascii(8, 'WAVEfmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, Mic.sampleRate, Endian.little);
    data.setUint32(28, Mic.sampleRate * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    ascii(36, 'data');
    data.setUint32(40, pcm.length * 2, Endian.little);
    for (var i = 0; i < pcm.length; i++) {
      data.setInt16(44 + i * 2, pcm[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('record echoCancel — $_status')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(12),
      child: SelectableText(
        _result ?? _status,
        style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
      ),
    ),
  );
}
