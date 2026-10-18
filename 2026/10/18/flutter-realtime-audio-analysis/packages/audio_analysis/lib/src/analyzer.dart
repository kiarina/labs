import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'consumer/audio_window_buffer.dart';
import 'consumer/consumers.dart';
import 'consumer/events.dart';
import 'hearing_store.dart';
import 'vad/voice_detector.dart';

class StageStats {
  int count = 0;
  int dropped = 0;
  int totalMs = 0;
  int maxMs = 0;
  double audioSeconds = 0;
  int queued = 0;

  void record(int ms, double audio) {
    count++;
    totalMs += ms;
    if (ms > maxMs) maxMs = ms;
    audioSeconds += audio;
  }

  /// Processing time / audio time (< 1 keeps up with real time).
  double get realTimeFactor => audioSeconds == 0 ? 0 : totalMs / 1000 / audioSeconds;

  Map<String, Object?> toJson() => {
        'count': count,
        'dropped': dropped,
        'queued': queued,
        'avg_ms': count == 0 ? 0 : totalMs / count,
        'max_ms': maxMs,
        'audio_s': audioSeconds,
        'rtf': realTimeFactor,
      };
}

/// Runs the pipeline on a 16 kHz mono stream:
///
///   feed → 512-sample chunks → VAD (stage 1, serial) → voices → [queue] →
///   speaker change + ASR + speaker embedding (stage 2) → store
///   feed → 10 s windows → [queue] → YAMNet + CLAP (stage 3) → store
///
/// Each queue is bounded; when a stage falls behind the oldest item is
/// dropped and counted, so the mic never blocks and memory stays bounded.
class AudioAnalyzer {
  AudioAnalyzer({
    this.stt,
    this.ambient,
    HearingStore? store,
    this.sampleRate = 16000,
    this.chunkSamples = 512,
    this.maxPendingChunks = 320, // ~10 s
    this.maxPendingVoices = 8,
    this.maxPendingWindows = 3,
  }) : store = store ?? HearingStore();

  final SttConsumer? stt;
  final AmbientConsumer? ambient;
  final HearingStore store;
  final int sampleRate;
  final int chunkSamples;
  final int maxPendingChunks;
  final int maxPendingVoices;
  final int maxPendingWindows;

  final vadStats = StageStats();
  final speechStats = StageStats();
  final ambientStats = StageStats();
  double lastVoiceProbability = 0;
  bool inVoice = false;

  final _events = StreamController<HearingEvent>.broadcast();
  final _errors = StreamController<Object>.broadcast();
  Stream<HearingEvent> get events => _events.stream;
  Stream<Object> get errors => _errors.stream;

  final _carry = <double>[];
  double? _carryTimestamp;
  final _chunks = Queue<(Float32List, double)>();
  final _voices = Queue<Voice>();
  final _windows = Queue<AudioWindow>();
  bool _vadRunning = false, _speechRunning = false, _ambientRunning = false;
  int _generation = 0;

  Map<String, Object?> statsJson() => {
        'vad': (vadStats..queued = _chunks.length).toJson(),
        'speech': (speechStats..queued = _voices.length).toJson(),
        'ambient': (ambientStats..queued = _windows.length).toJson(),
        'events': store.length,
      };

  /// [timestamp] is the Unix time (seconds) of the first sample.
  void feed(Float32List samples, double timestamp) {
    if (samples.isEmpty) return;
    ambient?.accept(samples, sampleRate, timestamp).forEach(_enqueueWindow);
    if (stt == null) return;
    if (_carry.isEmpty) _carryTimestamp = timestamp;
    _carry.addAll(samples);
    while (_carry.length >= chunkSamples) {
      final chunk = Float32List.fromList(_carry.sublist(0, chunkSamples));
      _carry.removeRange(0, chunkSamples);
      final ts = _carryTimestamp!;
      _carryTimestamp = ts + chunkSamples / sampleRate;
      _chunks.add((chunk, ts));
      while (_chunks.length > maxPendingChunks) {
        _chunks.removeFirst();
        vadStats.dropped++;
      }
    }
    _pumpVad();
  }

  /// End of input: emit the trailing voice and the last partial window,
  /// then wait until every queue is empty.
  Future<void> flush() async {
    // A tail much shorter than a chunk is too short for Silero's
    // convolutions (onnxruntime-web rejects it), so it is dropped.
    if (_carry.length < chunkSamples ~/ 2) _carry.clear();
    if (stt != null && _carry.isNotEmpty) {
      // the partial last chunk goes through the VAD too (kiarina's file
      // source yields it as well)
      _chunks.add((Float32List.fromList(_carry), _carryTimestamp!));
      _carry.clear();
      _pumpVad();
    }
    while (_vadRunning || _chunks.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    final voice = stt?.flush();
    if (voice != null) _enqueueVoice(voice);
    ambient?.flush().forEach(_enqueueWindow);
    while (_speechRunning || _ambientRunning || _voices.isNotEmpty || _windows.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Mic switched or stopped without flushing: forget partial state and
  /// ignore results of work already in flight.
  void reset() {
    _generation++;
    _carry.clear();
    _chunks.clear();
    _voices.clear();
    _windows.clear();
    stt?.voiceDetector.reset();
    ambient?.buffer.reset();
    inVoice = false;
  }

  Future<void> close() async {
    reset();
    await _events.close();
    await _errors.close();
  }

  void _enqueueVoice(Voice v) {
    _voices.add(v);
    while (_voices.length > maxPendingVoices) {
      _voices.removeFirst();
      speechStats.dropped++;
    }
    _pumpSpeech();
  }

  void _enqueueWindow(AudioWindow w) {
    if (ambient == null) return;
    _windows.add(w);
    while (_windows.length > maxPendingWindows) {
      _windows.removeFirst();
      ambientStats.dropped++;
    }
    _pumpAmbient();
  }

  Future<void> _pumpVad() async {
    if (_vadRunning) return;
    _vadRunning = true;
    try {
      while (_chunks.isNotEmpty) {
        try {
          final gen = _generation;
          final (chunk, ts) = _chunks.removeFirst();
          final sw = Stopwatch()..start();
          final r = await stt!.detect(chunk, sampleRate, ts);
          vadStats.record(sw.elapsedMilliseconds, chunk.length / sampleRate);
          if (gen != _generation) continue;
          lastVoiceProbability = r.probability;
          inVoice = stt!.voiceDetector.inVoice;
          if (r.voice != null) _enqueueVoice(r.voice!);
        } catch (e) {
          _errors.add(e);
        }
      }
    } finally {
      _vadRunning = false;
    }
  }

  Future<void> _pumpSpeech() async {
    if (_speechRunning) return;
    _speechRunning = true;
    try {
      while (_voices.isNotEmpty) {
        try {
          final gen = _generation;
          final voice = _voices.removeFirst();
          final sw = Stopwatch()..start();
          final events = await stt!.analyze(voice);
          speechStats.record(sw.elapsedMilliseconds, voice.samples.length / voice.sampleRate);
          if (gen != _generation) continue;
          for (final e in events) {
            store.add(e);
            _events.add(e);
          }
        } catch (e) {
          _errors.add(e);
        }
      }
    } finally {
      _speechRunning = false;
    }
  }

  Future<void> _pumpAmbient() async {
    if (_ambientRunning) return;
    _ambientRunning = true;
    try {
      while (_windows.isNotEmpty) {
        try {
          final gen = _generation;
          final w = _windows.removeFirst();
          final sw = Stopwatch()..start();
          final event = await ambient!.analyze(w);
          ambientStats.record(sw.elapsedMilliseconds, w.samples.length / w.sampleRate);
          if (gen != _generation) continue;
          store.add(event);
          _events.add(event);
        } catch (e) {
          _errors.add(e);
        }
      }
    } finally {
      _ambientRunning = false;
    }
  }
}
