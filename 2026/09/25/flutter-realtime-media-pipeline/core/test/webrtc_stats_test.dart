import 'package:realtime_core/realtime_core.dart';
import 'package:test/test.dart';

void main() {
  test('inbound stats become frame, audio and stats events', () {
    final converter = StatsEventConverter(side: StatsSide.inbound);
    List<Map<String, Object?>> reports(int frames, int bytes) => [
      {
        'type': 'inbound-rtp',
        'kind': 'video',
        'framesDecoded': frames,
        'frameWidth': 640,
        'frameHeight': 480,
        'framesPerSecond': 30,
        'bytesReceived': bytes,
        'jitter': 0.002,
        'packetsLost': 1,
      },
      // Android reports some numbers as strings.
      {'type': 'inbound-rtp', 'kind': 'audio', 'audioLevel': '0.25'},
      {
        'type': 'candidate-pair',
        'state': 'succeeded',
        'nominated': true,
        'currentRoundTripTime': 0.004,
      },
    ];

    final first = converter.convert(
      reports(10, 0),
      now: const Duration(seconds: 1),
      audioTrackEnabled: true,
      videoTrackEnabled: true,
    );
    expect(first.whereType<VideoFrameObserved>().single.frame.sequence, 10);
    expect(first.whereType<AudioLevelChanged>().single.level, 0.25);

    // No new frame decoded → no frame event.
    final same = converter.convert(
      reports(10, 0),
      now: const Duration(milliseconds: 1100),
      audioTrackEnabled: true,
      videoTrackEnabled: true,
    );
    expect(same.whereType<VideoFrameObserved>(), isEmpty);

    final next = converter.convert(
      reports(13, 12500),
      now: const Duration(milliseconds: 1200),
      audioTrackEnabled: false,
      videoTrackEnabled: true,
    );
    final frame = next.whereType<VideoFrameObserved>().single.frame;
    expect(frame.sequence, 13);
    expect(frame.width, 640);
    expect(next.whereType<AudioLevelChanged>(), isEmpty);
    final stats = next.whereType<MediaStatsUpdated>().single.stats;
    expect(stats.roundTripTime, 0.004);
    expect(stats.bitrateKbps, closeTo(1000, 1e-6));
  });

  test('outbound prefers media-source over outbound-rtp', () {
    const parser = WebRtcStatsParser();
    final sample = parser.parse([
      {'type': 'outbound-rtp', 'kind': 'video', 'framesEncoded': 5},
      {
        'type': 'media-source',
        'kind': 'video',
        'frames': 7,
        'width': 1280,
        'height': 720,
      },
      {'type': 'media-source', 'kind': 'audio', 'audioLevel': 0.5},
    ], side: StatsSide.outbound);
    expect(sample.frameCounter, 7);
    expect(sample.frameCounterSource, 'frames');
    expect(sample.width, 1280);
    expect(sample.audioLevel, 0.5);
    expect(sample.audioLevelSource, 'audioLevel');
  });
}
