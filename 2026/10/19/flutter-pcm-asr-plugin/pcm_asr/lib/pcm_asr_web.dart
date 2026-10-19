// Web implementation: the browser's SpeechRecognition fed from a
// MediaStreamTrack that the plugin synthesizes from the caller's PCM.
//
// Facts this relies on (research/web.md):
// - `start(track)` exists in desktop Chrome/Edge 135+ only.
// - The recognizer does not finalize when the track ends; `stop()` must be
//   called once the buffer has played, and the final result follows.
// - Playback through a MediaStream destination is real time, so a request
//   takes about the clip's duration.
// - Without an installed on-device pack the audio goes to the browser
//   vendor's servers; `support()` says so with `on_device: false`.
import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

import 'src/platform_interface.dart';
import 'src/types.dart';

@JS('SpeechRecognition')
external JSFunction? get _speechRecognitionCtor;

@JS('webkitSpeechRecognition')
external JSFunction? get _webkitSpeechRecognitionCtor;

extension type _Recognition._(JSObject _) implements JSObject {
  external set lang(String v);
  external set continuous(bool v);
  external set interimResults(bool v);
  external set maxAlternatives(int v);
  external set processLocally(bool v);
  external set onresult(JSFunction f);
  external set onerror(JSFunction f);
  external set onend(JSFunction f);
  external void start(web.MediaStreamTrack track);
  external void stop();
  external void abort();
}

extension type _RecognitionStatic._(JSObject _) implements JSObject {
  external JSPromise<JSString> available(JSObject options);
}

class PcmAsrWeb extends PcmAsrPlatform {
  PcmAsrWeb();

  static void registerWith(Registrar registrar) {
    PcmAsrPlatform.instance = PcmAsrWeb();
  }

  static const engineId = 'web.speech-recognition';

  /// Silence played after the segment before `stop()` is called.
  static Duration tailSilence = const Duration(milliseconds: 700);

  /// Silence played before the segment so its first syllable is not lost
  /// while the recognizer attaches to the track.
  static Duration leadSilence = const Duration(milliseconds: 300);

  final _availability = <String, String>{};

  final _running = <String, _Running>{};

  JSFunction? get _ctor => _speechRecognitionCtor ?? _webkitSpeechRecognitionCtor;

  /// `start(track)` shipped in desktop Chrome/Edge 135 (research/web.md).
  /// The JS function's `length` is 0 because the parameter is optional, so
  /// feature-detect by the static `available()` (Chrome 139+) or the version.
  bool get _hasTrackInput {
    final ctor = _ctor;
    if (ctor == null) return false;
    final ua = web.window.navigator.userAgent;
    if (ua.contains('Android') || ua.contains('Mobile')) return false;
    if (ctor.has('available')) return true;
    final m = RegExp(r'(?:Chrome|Edg)/(\d+)').firstMatch(ua);
    return m != null && int.parse(m.group(1)!) >= 135;
  }

  @override
  Future<RecognitionSupport> support({required String locale}) async {
    final ctor = _ctor;
    if (ctor == null) {
      return const RecognitionSupport(
        engine: 'none',
        supported: false,
        acceptsExternalPcm: false,
        onDevice: false,
        modelState: ModelState.unknown,
        reason: 'engine_unavailable',
      );
    }
    if (!_hasTrackInput) {
      return RecognitionSupport(
        engine: engineId,
        supported: false,
        acceptsExternalPcm: false,
        onDevice: false,
        modelState: ModelState.unknown,
        locale: locale,
        reason: 'no_track_input',
      );
    }
    var modelState = ModelState.unknown;
    var onDevice = false;
    try {
      final statics = ctor as _RecognitionStatic;
      final local = (await statics
              .available({'langs': [locale].jsify(), 'processLocally': true}.jsify() as JSObject)
              .toDart)
          .toDart;
      modelState = switch (local) {
        'available' => ModelState.installed,
        'downloadable' => ModelState.downloadable,
        'downloading' => ModelState.installing,
        _ => ModelState.unavailable,
      };
      onDevice = local == 'available';
    } catch (_) {
      // Older Chrome without available(): cloud only.
    }
    return RecognitionSupport(
      engine: engineId,
      supported: true,
      acceptsExternalPcm: true,
      onDevice: onDevice,
      modelState: modelState,
      locale: locale,
      sampleRates: const [16000],
      needsNetworkForModel: true,
      reason: null,
    );
  }

  /// `available()` for cloud recognition, cached per locale. Null when the
  /// browser has no `available()` (Chrome before 139).
  Future<String?> _availabilityOf(String locale) async {
    final cached = _availability[locale];
    if (cached != null) return cached;
    try {
      final statics = _ctor! as _RecognitionStatic;
      final value = (await statics
              .available({'langs': [locale].jsify(), 'processLocally': false}.jsify() as JSObject)
              .toDart)
          .toDart;
      _availability[locale] = value;
      return value;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> prepare({required String locale}) async {
    // No automatic model install: `install()` downloads about 60 MB into
    // the user's browser and prompts. The app decides; cloud works as is.
  }

  @override
  Future<TranscribeResult> transcribe(TranscribeRequest request) async {
    if (!_hasTrackInput) {
      throw const PcmAsrException(PcmAsrErrorCode.unsupportedPlatform, 'this browser cannot take a track as input');
    }
    if (_running.containsKey(request.id)) {
      throw PcmAsrException(PcmAsrErrorCode.engineFailure, 'request id already running: ${request.id}');
    }
    // Registered before the first await so that cancel() can reach it.
    final completer = Completer<TranscribeResult>();
    final running = _Running(completer);
    _running[request.id] = running;
    try {
      return await _transcribe(request, running, completer);
    } finally {
      _running.remove(request.id);
    }
  }

  Future<TranscribeResult> _transcribe(TranscribeRequest request, _Running running, Completer<TranscribeResult> completer) async {
    final availability = await _availabilityOf(request.locale);
    if (availability == 'unavailable') {
      throw PcmAsrException(PcmAsrErrorCode.unsupportedLocale, 'the browser reports ${request.locale} as unavailable');
    }
    final audio = request.audio;
    final frames = audio.frameCount;
    final samples = Float32List(frames);
    final view = ByteData.sublistView(audio.pcm16le);
    for (var i = 0; i < frames; i++) {
      // Mix down to mono: average the interleaved channels.
      var sum = 0;
      for (var c = 0; c < audio.channels; c++) {
        sum += view.getInt16((i * audio.channels + c) * 2, Endian.little);
      }
      samples[i] = sum / audio.channels / 32768.0;
    }
    // Calling stop() right when the source ends cut the last words in the
    // lab, so a short silent tail is appended before stop().
    final tail = (audio.sampleRate * tailSilence.inMilliseconds) ~/ 1000;
    final lead = (audio.sampleRate * leadSilence.inMilliseconds) ~/ 1000;
    final context = web.AudioContext(web.AudioContextOptions(sampleRate: audio.sampleRate));
    final buffer = context.createBuffer(1, lead + frames + tail, audio.sampleRate);
    buffer.copyToChannel(samples.toJS, 0, lead);
    final source = context.createBufferSource();
    source.buffer = buffer;
    final destination = context.createMediaStreamDestination();
    source.connect(destination);
    final track = destination.stream.getAudioTracks().toDart.first;

    final rec = (_ctor!.callAsConstructor<JSObject>()) as _Recognition;
    rec.lang = request.locale;
    // continuous=false returned only the first phrase of a segment that
    // contains a pause; continuous=true with stop() returns all of them.
    rec.continuous = true;
    rec.interimResults = true;
    rec.maxAlternatives = 1;
    running.rec = rec;
    if (running.cancelled) throw PcmAsrException(PcmAsrErrorCode.cancelled, 'cancelled: ${request.id}');
    final started = DateTime.now();
    var finalText = '';
    var lastInterim = '';
    rec.onresult = ((web.SpeechRecognitionEvent e) {
      final results = e.results;
      final parts = <String>[];
      var anyFinal = false;
      for (var i = 0; i < results.length; i++) {
        final r = results.item(i);
        parts.add(r.item(0).transcript);
        if (r.isFinal) anyFinal = true;
      }
      final text = parts.join();
      if (anyFinal) {
        finalText = text;
      } else {
        lastInterim = text;
      }
    }).toJS;
    rec.onerror = ((web.SpeechRecognitionErrorEvent e) {
      if (completer.isCompleted) return;
      final code = switch (e.error) {
        'language-not-supported' => PcmAsrErrorCode.unsupportedLocale,
        'aborted' => PcmAsrErrorCode.cancelled,
        'no-speech' => null,
        _ => PcmAsrErrorCode.engineFailure,
      };
      if (code == null) return; // ends with empty text
      completer.completeError(PcmAsrException(code, 'SpeechRecognition error: ${e.error}'));
    }).toJS;
    rec.onend = ((JSAny? _) {
      if (completer.isCompleted) return;
      completer.complete(TranscribeResult(
        id: request.id,
        text: finalText.isNotEmpty ? finalText : lastInterim,
        engine: engineId,
        locale: request.locale,
        elapsed: DateTime.now().difference(started),
      ));
    }).toJS;
    source.onended = ((JSAny? _) {
      // The recognizer never finalizes on its own; ask for the final result.
      if (!running.cancelled) rec.stop();
    }).toJS;
    try {
      await context.resume().toDart;
      rec.start(track);
      source.start();
      return await completer.future;
    } finally {
      track.stop();
      await context.close().toDart;
    }
  }

  @override
  Future<void> cancel(String id) async {
    final r = _running[id];
    if (r == null) return;
    r.cancelled = true;
    if (!r.completer.isCompleted) {
      r.completer.completeError(PcmAsrException(PcmAsrErrorCode.cancelled, 'cancelled: $id'));
    }
    try {
      r.rec?.abort();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    for (final id in _running.keys.toList()) {
      await cancel(id);
    }
  }
}

class _Running {
  _Running(this.completer);
  final Completer<TranscribeResult> completer;
  _Recognition? rec;
  bool cancelled = false;
}
