import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:media_taps/media_taps.dart';

/// What a run is asked to do. Everything comes from [envValue] so one build
/// can run every combination.
final class ScenarioConfig {
  /// `local` (getUserMedia only), `loopback` (plus an in-app PeerConnection
  /// pair sending audio+video), `audio-loopback` (the pair sends audio only).
  final String scenario;
  final int seconds;
  final int convertWidth;
  final bool deliver;

  /// Native only: ask flutter_webrtc to start the ADM recording without a
  /// PeerConnection (Android / iOS / macOS have it; Windows does not).
  final bool startRecording;

  const ScenarioConfig({
    required this.scenario,
    required this.seconds,
    required this.convertWidth,
    required this.deliver,
    required this.startRecording,
  });

  Map<String, Object?> toJson() => {
    'scenario': scenario,
    'seconds': seconds,
    'convertWidth': convertWidth,
    'deliver': deliver,
    'startRecording': startRecording,
  };
}

final class TapSpec {
  final String name;
  final MediaStreamTrack track;
  final bool local;
  final MediaStream? stream;

  TapSpec(this.name, this.track, {required this.local, this.stream});
}

/// Aggregates one tap over the measured window (after warm-up).
final class TapStats {
  final String name;
  int? id;
  String? attachError;
  Map<String, Object?>? first;
  Map<String, Object?>? last;
  Duration? firstAt;
  Duration? lastAt;
  int dartFrames = 0;
  int dartBytes = 0;
  int dartSamples = 0;
  double dartLumaSum = 0;
  double dartSquares = 0;
  final List<double> nativeRms = [];

  TapStats(this.name);

  Map<String, Object?> toJson() {
    final seconds = (firstAt == null || lastAt == null)
        ? 0.0
        : (lastAt! - firstAt!).inMicroseconds / 1e6;
    num? delta(String key) {
      final a = first?[key];
      final b = last?[key];
      if (a is! num || b is! num) return null;
      return b - a;
    }

    double? rate(String key) {
      final d = delta(key);
      return d == null || seconds <= 0 ? null : d / seconds;
    }

    final convertCount = delta('convertCount');
    final convertUs = delta('convertUsTotal');
    return {
      'name': name,
      'attachError': attachError,
      'windowSeconds': seconds,
      'callbacksPerSecond': rate('callbacks'),
      'width': last?['width'],
      'height': last?['height'],
      'rotation': last?['rotation'],
      'bufferType': last?['bufferType'],
      'sampleRate': last?['sampleRate'],
      'channels': last?['channels'],
      'framesPerChunk': last?['framesPerChunk'],
      'bitsPerSample': last?['bitsPerSample'],
      'convertAvgUs': (convertCount == null || convertCount == 0)
          ? null
          : convertUs! / convertCount,
      'convertMaxUs': last?['convertUsMax'],
      'droppedToDart': last?['droppedToDart'],
      // Root of the mean of the per-poll mean squares, so it matches dartRms
      // when each poll covers the same number of samples.
      'nativeRmsAvg': nativeRms.isEmpty
          ? null
          : math.sqrt(
              nativeRms.map((r) => r * r).reduce((a, b) => a + b) /
                  nativeRms.length,
            ),
      'dartFramesPerSecond': seconds > 0 ? dartFrames / seconds : null,
      'dartBytesPerSecond': seconds > 0 ? dartBytes / seconds : null,
      'dartSamplesPerSecond': seconds > 0 ? dartSamples / seconds : null,
      'dartLumaMean': dartFrames == 0 ? null : dartLumaSum / dartFrames,
      'dartRms': dartSamples == 0
          ? null
          : math.sqrt(dartSquares / dartSamples) / 32768,
      'lastCounters': last,
    };
  }
}

/// Runs a scenario and returns the report. [onStreams] lets the UI preview.
Future<Map<String, Object?>> runScenario(
  ScenarioConfig config, {
  void Function(MediaStream local, MediaStream? remote)? onStreams,
  void Function(String status)? onStatus,
}) async {
  final taps = MediaTaps.instance;
  final clock = Stopwatch()..start();
  final report = <String, Object?>{
    'platform': taps.platform,
    'config': config.toJson(),
  };
  final notes = <String>[];
  RTCPeerConnection? a;
  RTCPeerConnection? b;
  MediaStream? local;
  try {
    onStatus?.call('getUserMedia');
    local = await navigator.mediaDevices.getUserMedia({
      'audio': true,
      'video': {
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 30},
      },
    });
    if (config.startRecording && !kIsWeb) {
      try {
        await NativeAudioManagement.startLocalRecording();
        notes.add('startLocalRecording: ok');
      } catch (e) {
        notes.add('startLocalRecording: $e');
      }
    }

    final specs = <TapSpec>[
      TapSpec('local-video', local.getVideoTracks().first, local: true),
      TapSpec(
        'local-audio',
        local.getAudioTracks().first,
        local: true,
        stream: local,
      ),
    ];

    MediaStream? remote;
    if (config.scenario != 'local') {
      onStatus?.call('loopback');
      final audioOnly = config.scenario == 'audio-loopback';
      // No adaptation: the loopback is only here to exercise remote tracks
      // and the send path (see the pipeline lab's resolution experiment).
      final pcConfig = {
        'iceServers': <Map<String, dynamic>>[],
        'sdpSemantics': 'unified-plan',
        'enableCpuOveruseDetection': false,
      };
      final constraints = {
        'mandatory': {'googCpuOveruseDetection': false},
        'optional': [
          {'DtlsSrtpKeyAgreement': true},
        ],
      };
      a = await createPeerConnection(pcConfig, constraints);
      b = await createPeerConnection(pcConfig, constraints);
      final remoteReady = Completer<MediaStream>();
      final remoteTracks = <String, MediaStreamTrack>{};
      final expected = audioOnly ? 1 : 2;
      b.onTrack = (event) {
        remoteTracks[event.track.kind!] = event.track;
        if (remoteTracks.length == expected &&
            event.streams.isNotEmpty &&
            !remoteReady.isCompleted) {
          remoteReady.complete(event.streams.first);
        }
      };
      a.onIceCandidate = (c) => b?.addCandidate(c);
      b.onIceCandidate = (c) => a?.addCandidate(c);
      for (final t in local.getTracks()) {
        if (audioOnly && t.kind == 'video') continue;
        await a.addTrack(t, local);
      }
      final offer = await a.createOffer();
      await a.setLocalDescription(offer);
      await b.setRemoteDescription(offer);
      final answer = await b.createAnswer();
      await b.setLocalDescription(answer);
      await a.setRemoteDescription(answer);
      remote = await remoteReady.future.timeout(const Duration(seconds: 15));
      if (!audioOnly) {
        specs.add(
          TapSpec(
            'remote-video',
            remoteTracks['video']!,
            local: false,
            stream: remote,
          ),
        );
      }
      specs.add(
        TapSpec(
          'remote-audio',
          remoteTracks['audio']!,
          local: false,
          stream: remote,
        ),
      );
    }
    onStreams?.call(local, remote);

    onStatus?.call('attach');
    final stats = <int, TapStats>{};
    final all = <TapStats>[];
    for (final spec in specs) {
      final s = TapStats(spec.name);
      all.add(s);
      try {
        final id = await taps.attach(
          spec.track,
          local: spec.local,
          stream: spec.stream,
          options: TapOptions(
            convertWidth: spec.track.kind == 'video' ? config.convertWidth : 0,
            deliver: config.deliver,
          ),
        );
        s.id = id;
        stats[id] = s;
      } catch (e) {
        s.attachError = '$e';
      }
    }

    // Poll every 50 ms; the first 2 s are warm-up and not counted.
    // Timed from attach, so permission prompts do not eat the window.
    final start = clock.elapsed;
    final warmup = start + const Duration(seconds: 2);
    final end = start + Duration(seconds: config.seconds);
    final pollTimes = <int>[];
    final dartWorkUs = <int>[];
    onStatus?.call('running');
    while (clock.elapsed < end) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final t0 = clock.elapsedMicroseconds;
      final snapshots = await taps.poll();
      final t1 = clock.elapsedMicroseconds;
      final now = clock.elapsed;
      final counting = now >= warmup;
      if (counting) pollTimes.add(t1 - t0);
      for (final snap in snapshots) {
        final s = stats[snap.id];
        if (s == null) continue;
        if (!counting) continue;
        s.first ??= snap.counters;
        s.firstAt ??= now;
        s.last = snap.counters;
        s.lastAt = now;
        final rms = snap.counters['rms'];
        if (rms is num) s.nativeRms.add(rms.toDouble());
        // Touch every delivered byte, as a stand-in for real processing.
        for (final f in snap.frames) {
          var sum = 0;
          for (final v in f.luma) {
            sum += v;
          }
          s.dartFrames++;
          s.dartBytes += f.luma.length;
          s.dartLumaSum += sum / f.luma.length;
        }
        final pcm = snap.pcm;
        if (pcm != null) {
          for (final v in pcm) {
            s.dartSquares += v * v;
          }
          s.dartSamples += pcm.length;
          s.dartBytes += pcm.lengthInBytes;
        }
      }
      if (counting) dartWorkUs.add(clock.elapsedMicroseconds - t1);
    }

    pollTimes.sort();
    dartWorkUs.sort();
    int? pct(List<int> v, double p) =>
        v.isEmpty ? null : v[((v.length - 1) * p).round()];
    report['taps'] = [for (final s in all) s.toJson()];
    report['poll'] = {
      'count': pollTimes.length,
      'roundTripP50Us': pct(pollTimes, 0.5),
      'roundTripP95Us': pct(pollTimes, 0.95),
      'roundTripMaxUs': pct(pollTimes, 1),
      'dartWorkP50Us': pct(dartWorkUs, 0.5),
      'dartWorkP95Us': pct(dartWorkUs, 0.95),
      'dartWorkMaxUs': pct(dartWorkUs, 1),
    };
    for (final s in all) {
      if (s.id != null) await taps.detach(s.id!);
    }
  } catch (e, st) {
    report['error'] = '$e';
    debugPrint('$st');
  } finally {
    report['notes'] = notes;
    if (config.startRecording && !kIsWeb) {
      try {
        await NativeAudioManagement.stopLocalRecording();
      } catch (_) {}
    }
    await a?.close();
    await b?.close();
    for (final t in local?.getTracks() ?? const <MediaStreamTrack>[]) {
      await t.stop();
    }
    await local?.dispose();
  }
  return report;
}
