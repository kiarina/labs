import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:record/record.dart';

/// Continuous 16 kHz mono PCM from the microphone via `record`, kept in memory
/// with delivery statistics.
final class AudioProbe {
  static const sampleRate = 16000;

  final RecordConfig config;
  final AudioRecorder _recorder = AudioRecorder();
  final Stopwatch _clock = Stopwatch();
  StreamSubscription<Uint8List>? _sub;

  final List<Int16List> _chunks = [];
  int samples = 0;
  int chunks = 0;
  int oddBytes = 0;
  Duration? firstChunkAt;
  Duration? lastChunkAt;
  Duration maxGap = Duration.zero;
  final List<int> chunkSizes = [];
  Uint8List? _carry;

  AudioProbe({
    bool echoCancel = false,
    bool noiseSuppress = false,
    bool autoGain = false,
    AndroidAudioSource androidSource = AndroidAudioSource.defaultSource,
  }) : config = RecordConfig(
         encoder: AudioEncoder.pcm16bits,
         sampleRate: sampleRate,
         numChannels: 1,
         echoCancel: echoCancel,
         noiseSuppress: noiseSuppress,
         autoGain: autoGain,
         androidConfig: AndroidRecordConfig(audioSource: androidSource),
         iosConfig: const IosRecordConfig(
           categoryOptions: [
             IosAudioCategoryOption.defaultToSpeaker,
             IosAudioCategoryOption.mixWithOthers,
             IosAudioCategoryOption.allowBluetooth,
           ],
         ),
       );

  Future<void> start() async {
    if (!await _recorder.hasPermission()) {
      throw StateError('microphone permission denied');
    }
    _clock.start();
    final stream = await _recorder.startStream(config);
    _sub = stream.listen(_onChunk);
  }

  void _onChunk(Uint8List bytes) {
    final now = _clock.elapsed;
    if (lastChunkAt != null) {
      final gap = now - lastChunkAt!;
      if (gap > maxGap) maxGap = gap;
    }
    firstChunkAt ??= now;
    lastChunkAt = now;
    chunks++;
    if (chunkSizes.length < 32) chunkSizes.add(bytes.length);
    // Chunks may split a sample; carry the odd byte to the next chunk.
    var data = bytes;
    final carry = _carry;
    if (carry != null) {
      data = Uint8List(carry.length + bytes.length)
        ..setAll(0, carry)
        ..setAll(carry.length, bytes);
      _carry = null;
    }
    if (data.length.isOdd) {
      oddBytes++;
      _carry = Uint8List.fromList([data.last]);
      data = Uint8List.sublistView(data, 0, data.length - 1);
    }
    final pcm = Uint8List.fromList(data).buffer.asInt16List();
    _chunks.add(pcm);
    samples += pcm.length;
  }

  /// All samples captured from sample index [from] (inclusive).
  Int16List samplesFrom(int from, [int? to]) {
    final end = math.min(to ?? samples, samples);
    final out = Int16List(math.max(0, end - from));
    var offset = 0;
    var written = 0;
    for (final c in _chunks) {
      final cEnd = offset + c.length;
      if (cEnd > from && offset < end) {
        final s = math.max(from, offset) - offset;
        final e = math.min(end, cEnd) - offset;
        out.setRange(written, written + (e - s), c, s);
        written += e - s;
      }
      offset = cEnd;
    }
    return out;
  }

  Map<String, Object?> stats() {
    final span = (firstChunkAt != null && lastChunkAt != null)
        ? (lastChunkAt! - firstChunkAt!).inMicroseconds / 1e6
        : 0.0;
    return {
      'requested': {
        'sampleRate': config.sampleRate,
        'channels': config.numChannels,
        'echoCancel': config.echoCancel,
        'noiseSuppress': config.noiseSuppress,
        'autoGain': config.autoGain,
        'androidSource': config.androidConfig.audioSource.name,
      },
      'chunks': chunks,
      'samples': samples,
      'samplesPerSecond': span > 0 ? samples / span : null,
      'chunksPerSecond': span > 0 ? chunks / span : null,
      'firstChunkMs': firstChunkAt?.inMilliseconds,
      'maxGapMs': maxGap.inMicroseconds / 1000,
      'chunkBytes': chunkSizes.toSet().toList()..sort(),
      'oddByteChunks': oddBytes,
    };
  }

  Future<void> stop() async {
    await _recorder.stop();
    await _sub?.cancel();
    await _recorder.dispose();
  }
}
