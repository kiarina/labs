import 'dart:typed_data';

class Wav {
  Wav(this.samples, this.sampleRate);

  final Float32List samples;
  final int sampleRate;

  /// Minimal RIFF/WAVE reader for mono PCM16.
  static Wav parse(Uint8List bytes) {
    final d = ByteData.sublistView(bytes);
    var offset = 12;
    int? rate, channels, bits;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final size = d.getUint32(offset + 4, Endian.little);
      final body = offset + 8;
      if (id == 'fmt ') {
        channels = d.getUint16(body + 2, Endian.little);
        rate = d.getUint32(body + 4, Endian.little);
        bits = d.getUint16(body + 14, Endian.little);
      } else if (id == 'data') {
        if (channels != 1 || bits != 16) throw FormatException('need mono PCM16, got $channels ch $bits bit');
        final n = size ~/ 2;
        final out = Float32List(n);
        for (var i = 0; i < n; i++) {
          out[i] = d.getInt16(body + i * 2, Endian.little) / 32768.0;
        }
        return Wav(out, rate!);
      }
      offset = body + size + (size & 1);
    }
    throw const FormatException('no data chunk');
  }
}
