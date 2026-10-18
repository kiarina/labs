import 'dart:typed_data';

class StreamCase {
  const StreamCase(
    this.name,
    this.durationSeconds, {
    this.delayMs = 0,
    this.cancelAfterSeconds = 0,
  });
  final String name;
  final int durationSeconds, delayMs, cancelAfterSeconds;
  static StreamCase parse(String s) => switch (s) {
    'slow' => const StreamCase('slow', 60, delayMs: 25),
    'cancel' => const StreamCase('cancel', 600, cancelAfterSeconds: 5),
    'restart' => const StreamCase('restart', 6),
    _ => StreamCase(s, int.parse(s)),
  };
}

/// Only generated FFmpeg MJPEG is accepted. Escaped scan bytes cannot contain
/// an unescaped EOI. Cap rejects malformed/unbounded packets rather than grow.
class JpegChunks {
  JpegChunks({required this.maxBytes});
  final int maxBytes;
  final _buffer = <int>[];
  int peakBytes = 0;
  Iterable<Uint8List> add(Uint8List input) sync* {
    // Append incrementally so even a large socket read cannot exceed the cap.
    for (final byte in input) {
      _buffer.add(byte);
      if (_buffer.length > peakBytes) peakBytes = _buffer.length;
      if (_buffer.length > maxBytes)
        throw StateError('JPEG exceeds buffer cap');
      if (_buffer.length >= 2 &&
          _buffer[_buffer.length - 2] == 255 &&
          byte == 217) {
        if (_buffer[0] != 255 || _buffer[1] != 216)
          throw FormatException('Missing JPEG SOI');
        final out = Uint8List.fromList(_buffer);
        _buffer.clear();
        yield out;
      }
    }
  }

  void finish() {
    if (_buffer.isNotEmpty) throw FormatException('Truncated JPEG');
  }
}
