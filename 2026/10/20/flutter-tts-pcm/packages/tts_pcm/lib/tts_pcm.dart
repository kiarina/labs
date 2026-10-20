/// Speech synthesis to PCM with the OS voices.
///
/// Nothing is played: the caller gets 16-bit mono PCM and owns the speaker,
/// so it knows exactly what was played and when (for an echo canceller's
/// reference, or to mark its own speech in what the microphone hears).
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// One voice the OS offers.
final class TtsVoice {
  final String id;
  final String name;

  /// BCP 47, e.g. `ja-JP`.
  final String language;

  /// Engine-specific quality label (Apple: default / enhanced / premium).
  final String? quality;

  const TtsVoice({
    required this.id,
    required this.name,
    required this.language,
    this.quality,
  });

  factory TtsVoice._fromMap(Map<Object?, Object?> m) => TtsVoice(
    id: m['id']! as String,
    name: m['name']! as String,
    language: m['language']! as String,
    quality: m['quality'] as String?,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'language': language,
    'quality': quality,
  };
}

/// A piece of synthesized audio: 16-bit little-endian mono PCM.
final class TtsChunk {
  final Int16List samples;
  final int sampleRate;

  /// What the engine produced before conversion to 16-bit mono, for
  /// diagnostics (e.g. `float32 22050 Hz 1 ch`).
  final String? nativeFormat;

  const TtsChunk(this.samples, this.sampleRate, [this.nativeFormat]);

  Duration get duration =>
      Duration(microseconds: samples.length * 1000000 ~/ sampleRate);
}

final class TtsPcmException implements Exception {
  final String message;
  const TtsPcmException(this.message);
  @override
  String toString() => 'TtsPcmException: $message';
}

class TtsPcm {
  TtsPcm._() {
    _channel.setMethodCallHandler(_onCall);
  }

  static final TtsPcm instance = TtsPcm._();
  static const _channel = MethodChannel('tts_pcm');

  final Map<String, StreamController<TtsChunk>> _running = {};

  /// Chunks that arrived for a request no longer listened to (after a
  /// cancel). The engine should stop producing them; this counts how often
  /// it did not.
  int lateChunks = 0;
  int _next = 0;

  /// Voices the OS offers, optionally only those whose language starts with
  /// [language] (`ja` matches `ja-JP`).
  Future<List<TtsVoice>> voices({String? language}) async {
    final list = await _channel.invokeListMethod<Object?>('voices');
    final all = [
      for (final v in list ?? const <Object?>[])
        TtsVoice._fromMap(v! as Map<Object?, Object?>),
    ];
    if (language == null) return all;
    final l = language.toLowerCase();
    return [
      for (final v in all)
        if (v.language.toLowerCase().replaceAll('_', '-').startsWith(l)) v,
    ];
  }

  /// Synthesizes [text] and streams its PCM. Pass [voice] (a [TtsVoice.id])
  /// or [language] (the OS default voice for it). [rate] is relative to the
  /// engine's normal speed (1.0). Cancel by cancelling the subscription.
  Stream<TtsChunk> synthesize(
    String text, {
    String? language,
    String? voice,
    double rate = 1.0,
  }) {
    final id = 'tts${_next++}';
    late final StreamController<TtsChunk> controller;
    controller = StreamController<TtsChunk>(
      onListen: () {
        _running[id] = controller;
        _channel
            .invokeMethod<void>('synthesize', {
              'id': id,
              'text': text,
              'language': language,
              'voice': voice,
              'rate': rate,
            })
            .catchError((Object e) {
              _finish(id, error: TtsPcmException('$e'));
            });
      },
      onCancel: () async {
        if (_running.remove(id) != null) {
          await _channel.invokeMethod<void>('cancel', {'id': id});
        }
      },
    );
    return controller.stream;
  }

  void _finish(String id, {Object? error}) {
    final c = _running.remove(id);
    if (c == null) return;
    if (error != null) c.addError(error);
    c.close();
  }

  Future<void> _onCall(MethodCall call) async {
    final args = (call.arguments as Map<Object?, Object?>?) ?? const {};
    final id = args['id'] as String?;
    if (id == null) return;
    switch (call.method) {
      case 'chunk':
        if (!_running.containsKey(id)) {
          lateChunks++;
          return;
        }
        final bytes = args['pcm']! as Uint8List;
        final copy = Uint8List.fromList(bytes);
        _running[id]?.add(
          TtsChunk(
            copy.buffer.asInt16List(0, copy.length ~/ 2),
            args['sampleRate']! as int,
            args['format'] as String?,
          ),
        );
      case 'done':
        _finish(id);
      case 'error':
        _finish(id, error: TtsPcmException(args['message'] as String? ?? ''));
    }
  }
}
