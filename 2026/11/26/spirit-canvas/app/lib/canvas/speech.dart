import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:tts_pcm/tts_pcm.dart';

import 'canvas_model.dart';

/// One line to say.
class SpeechLine {
  SpeechLine({
    required this.text,
    this.id,
    this.vrm,
    this.caption,
    this.rate = 1.0,
    this.language = 'ja-JP',
  });

  final String text;

  /// Given back in the `spoken` event when the line ends.
  final String? id;

  /// The VRM element whose mouth follows the voice.
  final String? vrm;

  /// A text element that shows the line while it is said.
  final String? caption;
  final double rate;
  final String language;
}

/// Says lines with the OS voice (tts_pcm: synthesized to PCM, nothing played
/// by the OS), one after another: writes each to a WAV, plays it, and moves
/// the VRM's mouth with the loudness of the voice (40 ms steps). When a line
/// ends, [onSpoken] gets its id.
class SpeechPlayer {
  SpeechPlayer(this.canvas);

  final CanvasController canvas;
  void Function(String id, String text)? onSpoken;
  void Function(String problem)? onProblem;

  final _queue = <SpeechLine>[];
  final _player = AudioPlayer();
  bool _busy = false;
  StreamSubscription<void>? _done;
  Completer<void>? _playing;
  int _count = 0;

  bool get speaking => _busy;

  void say(SpeechLine line, {bool interrupt = false}) {
    if (interrupt) stop();
    _queue.add(line);
    if (!_busy) unawaited(_next());
  }

  void stop() {
    _queue.clear();
    _player.stop();
    if (!(_playing?.isCompleted ?? true)) _playing!.complete();
    canvas.mouths.clear();
  }

  Future<void> _next() async {
    if (_queue.isEmpty) {
      _busy = false;
      return;
    }
    _busy = true;
    final line = _queue.removeAt(0);
    final id = line.id ?? 'speech-${++_count}';
    try {
      if (!TtsPcm.isSupported) {
        throw StateError('no OS speech on this platform');
      }
      final samples = <int>[];
      var rate = 0;
      await for (final chunk in TtsPcm.instance.synthesize(
        line.text,
        language: line.language,
        rate: line.rate,
      )) {
        rate = chunk.sampleRate;
        samples.addAll(chunk.samples);
      }
      if (samples.isEmpty || rate == 0) {
        throw StateError('the voice gave no audio');
      }
      final pcm = Int16List.fromList(samples);
      final file = File(
        '${Directory.systemTemp.path}/spirit-canvas-speech-$id.wav',
      );
      await file.writeAsBytes(_wav(pcm, rate));
      final env = _envelope(pcm, rate);
      if (line.caption != null) {
        canvas.update(line.caption!, {'text': line.text});
      }
      _playing = Completer<void>();
      _done?.cancel();
      _done = _player.onPlayerComplete.listen((_) {
        if (!(_playing?.isCompleted ?? true)) _playing!.complete();
      });
      await _player.play(DeviceFileSource(file.path));
      if (line.vrm != null) {
        canvas.mouths[line.vrm!] = (levels: env, start: DateTime.now());
      }
      // The voice's own length, in case the end is not reported.
      final length = Duration(milliseconds: (pcm.length * 1000 / rate).round());
      await _playing!.future.timeout(
        length + const Duration(seconds: 2),
        onTimeout: () {},
      );
      if (line.vrm != null) canvas.mouths.remove(line.vrm!);
      unawaited(file.delete().catchError((_) => file));
      onSpoken?.call(id, line.text);
    } on Object catch (e) {
      onProblem?.call('speak "$id": $e');
    }
    await _next();
  }

  void dispose() {
    _done?.cancel();
    _player.dispose();
  }

  /// Loudness per 40 ms, 0..1 (scaled so the loud parts reach about 1).
  static List<double> _envelope(Int16List pcm, int rate) {
    final step = math.max(1, (rate * 0.04).round());
    final out = <double>[];
    for (var i = 0; i < pcm.length; i += step) {
      var sum = 0.0;
      final end = math.min(pcm.length, i + step);
      for (var j = i; j < end; j++) {
        final v = pcm[j] / 32768;
        sum += v * v;
      }
      out.add(math.sqrt(sum / (end - i)));
    }
    final sorted = [...out]..sort();
    final loud = sorted.isEmpty
        ? 1.0
        : sorted[(sorted.length * 0.95).floor().clamp(0, sorted.length - 1)];
    return [for (final v in out) (v / (loud == 0 ? 1 : loud)).clamp(0.0, 1.0)];
  }

  static Uint8List _wav(Int16List pcm, int rate) {
    final data = pcm.buffer.asUint8List(pcm.offsetInBytes, pcm.lengthInBytes);
    final b = BytesBuilder();
    void u32(int v) => b.add(
      (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List(),
    );
    void u16(int v) => b.add(
      (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List(),
    );
    b.add('RIFF'.codeUnits);
    u32(36 + data.length);
    b.add('WAVEfmt '.codeUnits);
    u32(16);
    u16(1);
    u16(1);
    u32(rate);
    u32(rate * 2);
    u16(2);
    u16(16);
    b.add('data'.codeUnits);
    u32(data.length);
    b.add(data);
    return b.toBytes();
  }
}
