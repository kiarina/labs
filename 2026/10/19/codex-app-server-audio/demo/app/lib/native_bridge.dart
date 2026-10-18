import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
// Native registry IDs are wrapped by the plugin's platform implementation.
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/media_stream_impl.dart';

class CaptureBridge {
  static const _channel = MethodChannel('external_capture');
  Future<MediaStream> create() async {
    if (Platform.isMacOS || Platform.isIOS) {
      await _channel.invokeMethod<void>('prepare');
    }
    await WebRTC.initialize();
    final data = await _channel.invokeMapMethod<String, dynamic>('create');
    // Construct from the registered IDs. The Windows wrapper's AddTrack can
    // report duplicate audio entries through mediaStreamGetTracks.
    Map<String, dynamic> track(String kind) => {
      'id': data!['${kind}TrackId'],
      'label': 'external-$kind',
      'kind': kind,
      'enabled': true,
      'settings': <String, dynamic>{},
    };
    return MediaStreamNative.fromMap({
      'streamId': data!['streamId'],
      'ownerTag': 'local',
      'audioTracks': [track('audio')],
      'videoTracks': [track('video')],
    });
  }

  Future<void> pushAudio(Uint8List bytes) =>
      _channel.invokeMethod('pushAudio', {'bytes': bytes});
  Future<void> pushVideo(
    Uint8List bytes,
    int width,
    int height,
    int timestampUs,
  ) => _channel.invokeMethod('pushVideo', {
    'bytes': bytes,
    'width': width,
    'height': height,
    'timestampUs': timestampUs,
  });
  Future<void> flush() => _channel.invokeMethod('flush');
  Future<void> dispose() => _channel.invokeMethod('dispose');
}
