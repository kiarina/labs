/// The message framing of the app under study: JSON text sent as `J<json>`
/// whole, or as `C<id>:<index>/<count>:<part>` chunks of at most
/// [chunkChars] UTF-16 code units. Copied in behaviour, not in code.
library;

import 'dart:convert';
import 'dart:math';

const chunkChars = 16000;

/// Splits one JSON message into frames.
///
/// With [asciiOnly], characters outside ASCII are written as `\uXXXX`
/// escapes (still the same JSON). webrtc_dart 0.25.3 sends a string's UTF-16
/// code units truncated to bytes, so only ASCII survives its sendString.
List<String> encodeFrames(Map<String, dynamic> message, int seq, {bool asciiOnly = false}) {
  var s = jsonEncode(message);
  if (asciiOnly) s = escapeNonAscii(s);
  if (s.length <= chunkChars) return ['J$s'];
  final n = (s.length / chunkChars).ceil();
  return [
    for (var i = 0; i < n; i++)
      'C$seq:$i/$n:${s.substring(i * chunkChars, min(s.length, (i + 1) * chunkChars))}',
  ];
}

/// Reassembles frames into JSON messages.
class FrameReader {
  final _parts = <String, List<String?>>{};

  /// Returns the message the frame completes, or null.
  Map<String, dynamic>? add(String text) {
    if (text.startsWith('J')) return _decode(text.substring(1));
    if (!text.startsWith('C')) return null;
    final head = text.indexOf(':');
    final head2 = text.indexOf(':', head + 1);
    final id = text.substring(1, head);
    final pos = text.substring(head + 1, head2).split('/');
    final index = int.parse(pos[0]), count = int.parse(pos[1]);
    final parts = _parts.putIfAbsent(id, () => List<String?>.filled(count, null));
    parts[index] = text.substring(head2 + 1);
    if (parts.every((p) => p != null)) {
      _parts.remove(id);
      return _decode(parts.join());
    }
    return null;
  }

  Map<String, dynamic> _decode(String s) =>
      (jsonDecode(s) as Map).cast<String, dynamic>();
}

/// Writes every UTF-16 code unit above 0x7F as a JSON `\uXXXX` escape. Only
/// valid for JSON text, where such characters can only be inside strings.
String escapeNonAscii(String json) {
  final b = StringBuffer();
  for (final u in json.codeUnits) {
    if (u < 0x80) {
      b.writeCharCode(u);
    } else {
      b.write('\\u${u.toRadixString(16).padLeft(4, '0')}');
    }
  }
  return b.toString();
}

/// webrtc_dart 0.25.3 turns a received string's UTF-8 bytes into one
/// character each (Latin-1). This reads the bytes again as UTF-8.
String fixReceived(String latin1Text) => utf8.decode(latin1.encode(latin1Text));
