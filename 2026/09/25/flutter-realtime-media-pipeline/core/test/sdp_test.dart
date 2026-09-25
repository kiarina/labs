import 'package:realtime_core/realtime_core.dart';
import 'package:test/test.dart';

void main() {
  test('adds bitrate params to video payloads only', () {
    const sdp =
        'v=0\r\n'
        'm=audio 9 UDP/TLS/RTP/SAVPF 111\r\n'
        'a=fmtp:111 minptime=10;useinbandfec=1\r\n'
        'm=video 9 UDP/TLS/RTP/SAVPF 96 97\r\n'
        'a=rtpmap:96 VP8/90000\r\n'
        'a=rtpmap:97 rtx/90000\r\n'
        'a=fmtp:97 apt=96\r\n';
    final out = withVideoBitrate(sdp, startKbps: 2500, minKbps: 1500);
    expect(out, contains('a=fmtp:111 minptime=10;useinbandfec=1\r\n'));
    expect(
      out,
      contains(
        'a=fmtp:97 apt=96;x-google-start-bitrate=2500;x-google-min-bitrate=1500',
      ),
    );
    expect(
      out,
      contains(
        'a=fmtp:96 x-google-start-bitrate=2500;x-google-min-bitrate=1500\r\n',
      ),
    );
    expect(out.endsWith('\r\n'), isTrue);
    // Idempotent.
    expect(
      withVideoBitrate(
        out,
        startKbps: 2500,
        minKbps: 1500,
      ).split('x-google-start-bitrate').length,
      out.split('x-google-start-bitrate').length,
    );
  });
}
