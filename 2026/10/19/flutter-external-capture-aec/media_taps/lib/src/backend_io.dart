import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../media_taps.dart';

MediaTapsBackend createBackend() => _ChannelBackend();

final class _ChannelBackend implements MediaTapsBackend {
  static const _channel = MethodChannel('media_taps');

  @override
  String get platform => Platform.operatingSystem;

  @override
  Future<int> attach(
    MediaStreamTrack track, {
    required bool local,
    MediaStream? stream,
    TapOptions options = const TapOptions(),
  }) async {
    final id = await _channel.invokeMethod<int>('attach', {
      'trackId': track.id,
      'kind': track.kind,
      'local': local,
      ...options.toMap(),
    });
    return id!;
  }

  @override
  Future<void> detach(int id) => _channel.invokeMethod('detach', {'id': id});

  @override
  Future<List<TapSnapshot>> poll() async {
    final list = await _channel.invokeListMethod<Map<Object?, Object?>>('poll');
    return [
      for (final m in list ?? const <Map<Object?, Object?>>[])
        TapSnapshot(
          id: m['id']! as int,
          kind: m['kind'] == 'video' ? TapKind.video : TapKind.audio,
          counters: Map<String, Object?>.from(m['counters']! as Map),
          frames: [
            for (final f in (m['frames'] as List?) ?? const [])
              VideoPayload(
                (f as Map)['width']! as int,
                f['height']! as int,
                f['luma']! as Uint8List,
              ),
          ],
          pcm: switch (m['pcm']) {
            // The codec may hand back a view at an odd offset; Int16 views
            // need 2-byte alignment, so copy in that case.
            final Uint8List bytes when bytes.offsetInBytes.isEven =>
              bytes.buffer.asInt16List(
                bytes.offsetInBytes,
                bytes.lengthInBytes ~/ 2,
              ),
            final Uint8List bytes => Uint8List.fromList(
              bytes,
            ).buffer.asInt16List(),
            _ => null,
          },
        ),
    ];
  }
}
