import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

/// One microphone setting under test.
final class Variant {
  final String name;
  final bool echoCancel;
  final bool noiseSuppress;
  final bool autoGain;

  /// Android: voiceCommunication source + MODE_IN_COMMUNICATION, and the
  /// far-end playback as a voice-communication stream.
  final bool androidVoice;

  const Variant(
    this.name, {
    this.echoCancel = false,
    this.noiseSuppress = false,
    this.autoGain = false,
    this.androidVoice = false,
  });

  static const all = [
    Variant('raw'),
    Variant('ec', echoCancel: true),
    Variant('ec-ns-agc', echoCancel: true, noiseSuppress: true, autoGain: true),
    Variant(
      'voice-raw',
      androidVoice: true,
    ),
    Variant('voice-ec', echoCancel: true, androidVoice: true),
    Variant(
      'voice-ec-ns-agc',
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
      androidVoice: true,
    ),
  ];

  static Variant byName(String name) => all.firstWhere((v) => v.name == name);

  RecordConfig get config => RecordConfig(
    encoder: AudioEncoder.pcm16bits,
    sampleRate: Mic.sampleRate,
    numChannels: 1,
    echoCancel: echoCancel,
    noiseSuppress: noiseSuppress,
    autoGain: autoGain,
    androidConfig: AndroidRecordConfig(
      audioSource: androidVoice
          ? AndroidAudioSource.voiceCommunication
          : AndroidAudioSource.defaultSource,
      audioManagerMode: androidVoice
          ? AudioManagerMode.modeInCommunication
          : AudioManagerMode.modeNormal,
      speakerphone: androidVoice,
    ),
    iosConfig: const IosRecordConfig(
      categoryOptions: [
        IosAudioCategoryOption.defaultToSpeaker,
        IosAudioCategoryOption.mixWithOthers,
      ],
    ),
  );

  Map<String, Object?> toJson() => {
    'name': name,
    'echoCancel': echoCancel,
    'noiseSuppress': noiseSuppress,
    'autoGain': autoGain,
    'androidVoice': androidVoice,
  };
}

/// Continuous 16 kHz mono PCM from `record.startStream`, kept in memory with
/// the arrival time of each chunk so phases can be cut by wall clock.
final class Mic {
  static const sampleRate = 16000;

  final Variant variant;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final BytesBuilder _bytes = BytesBuilder(copy: false);
  int _byteCount = 0;

  /// Epoch ms at which the first sample arrived (estimated from the first
  /// chunk's arrival minus its duration).
  int? firstSampleEpochMs;
  int chunks = 0;
  int maxGapMs = 0;
  int? _lastChunkMs;

  Mic(this.variant);

  int get samples => _byteCount ~/ 2;

  Future<void> start() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('microphone permission denied');
    }
    final stream = await _recorder.startStream(variant.config);
    _sub = stream.listen(_onChunk);
  }

  void _onChunk(Uint8List data) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastChunkMs != null) {
      maxGapMs = math.max(maxGapMs, now - _lastChunkMs!);
    }
    _lastChunkMs = now;
    firstSampleEpochMs ??= now - (data.length ~/ 2) * 1000 ~/ sampleRate;
    chunks++;
    _bytes.add(data);
    _byteCount += data.length;
  }

  Future<Int16List> stop() async {
    await _recorder.stop();
    await _sub?.cancel();
    await _recorder.dispose();
    final bytes = _bytes.takeBytes();
    // Copy so the Int16 view starts aligned (host order is little-endian on
    // every target here).
    final copy = Uint8List.fromList(
      Uint8List.sublistView(bytes, 0, bytes.length & ~1),
    );
    return copy.buffer.asInt16List();
  }
}
