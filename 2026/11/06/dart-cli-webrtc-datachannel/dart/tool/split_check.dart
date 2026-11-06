// For each size case of the probe: does a chunk boundary of the app's
// framing fall inside a surrogate pair?
import 'dart:convert';
import 'dart:math';
import 'package:dart_cli_webrtc_probe/frames.dart';

String mixed(int n) {
  const pieces = ['spirit ', '精霊の庭で', '🌱', 'body', '"quote"\\', '\n', 'ｶﾅ', '👩‍💻'];
  final rnd = Random(n);
  final b = StringBuffer();
  while (b.length < n) {
    b.write(pieces[rnd.nextInt(pieces.length)]);
  }
  var s = b.toString();
  while (s.length > n) {
    s = s.substring(0, s.length - 1);
    final last = s.codeUnitAt(s.length - 1);
    if (last >= 0xD800 && last <= 0xDBFF) s = s.substring(0, s.length - 1);
  }
  return s;
}

void main() {
  for (final n in [100, 15000, 16001, 65536, 262144, 1048576]) {
    final s = jsonEncode({'kind': 'size', 'n': n, 'text': mixed(n)});
    var splits = 0;
    for (var i = chunkChars; i < s.length; i += chunkChars) {
      final u = s.codeUnitAt(i - 1);
      if (u >= 0xD800 && u <= 0xDBFF) splits++;
    }
    print('$n: frames=${(s.length / chunkChars).ceil()} boundaries_inside_pair=$splits');
  }
}
