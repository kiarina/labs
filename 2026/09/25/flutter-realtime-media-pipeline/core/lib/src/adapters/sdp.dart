/// SDP rewriting used by the resolution experiments. Pure string work, so it
/// lives in core and is unit-tested.
library;

/// Adds libwebrtc's `x-google-{start,min,max}-bitrate` (kbps) to every video
/// payload type, so bandwidth estimation does not start from its low default
/// and push the encoder (and, natively, the camera) to a small resolution.
String withVideoBitrate(
  String sdp, {
  required int startKbps,
  int? minKbps,
  int? maxKbps,
}) {
  final eol = sdp.contains('\r\n') ? '\r\n' : '\n';
  final lines = sdp.split(eol);
  final params = [
    'x-google-start-bitrate=$startKbps',
    if (minKbps != null) 'x-google-min-bitrate=$minKbps',
    if (maxKbps != null) 'x-google-max-bitrate=$maxKbps',
  ].join(';');

  final out = <String>[];
  var inVideo = false;
  var payloads = <String>[];
  final withFmtp = <String>{};

  void flushMissingFmtp() {
    for (final pt in payloads) {
      if (!withFmtp.contains(pt)) out.add('a=fmtp:$pt $params');
    }
  }

  for (final line in lines) {
    if (line.startsWith('m=')) {
      if (inVideo) flushMissingFmtp();
      inVideo = line.startsWith('m=video');
      payloads = inVideo ? line.split(' ').skip(3).toList() : [];
      withFmtp.clear();
      out.add(line);
      continue;
    }
    if (inVideo && line.startsWith('a=fmtp:')) {
      final pt = line.substring(7).split(' ').first;
      if (payloads.contains(pt)) {
        withFmtp.add(pt);
        if (!line.contains('x-google-start-bitrate')) {
          out.add('$line;$params');
          continue;
        }
      }
    }
    out.add(line);
  }
  if (inVideo) {
    // Keep a trailing empty line (SDP ends with CRLF) after the additions.
    final trailing = out.isNotEmpty && out.last.isEmpty
        ? out.removeLast()
        : null;
    flushMissingFmtp();
    if (trailing != null) out.add(trailing);
  }
  return out.join(eol);
}
